// Local validation only. Supply your own licensed exchange-set library; no chart files are bundled.
import Foundation
@main struct Check {
 @MainActor static func main() async throws {
  guard CommandLine.arguments.count == 2 else { fatalError("Pass a local ExperimentalENC library directory containing V-PAC-A.") }
  let root = URL(fileURLWithPath:CommandLine.arguments[1])
  precondition(OfflineENCPackagePolicy.maximumUsageBand(metresAcross:400_000) == 2)
  precondition(OfflineENCPackagePolicy.maximumUsageBand(metresAcross:100_000) == 3)
  precondition(OfflineENCPackagePolicy.maximumUsageBand(metresAcross:40_000) == 4)
  precondition(OfflineENCPackagePolicy.maximumUsageBand(metresAcross:8_000) == 5)
  precondition(OfflineENCPackagePolicy.maximumUsageBand(metresAcross:1_000) == 6)
  precondition(OfflineENCPackagePolicy.usageBand(cellID:"CA571548") == 5)
  let store = OfflineENCStore(root:root)
  let collection = store.collections.first!
  let a = collection.cells.first { $0.cellID == "CA571548" }!
  let b = collection.cells.first { $0.cellID == "CA571549" }!
  let session = OfflineENCPackageSession()
  let originalSelection = store.selectedChartID
  let clock = Date()
  await session.load([a,b],collection:collection,store:store)
  precondition(session.failures.isEmpty && session.cells.count == 2)
  precondition(store.selectedChartID == originalSelection)
  precondition(session.featureBounds.count == 2)
  precondition(session.cells.allSatisfy { $0.features.map(\.portrayalOrder) == $0.features.map(\.portrayalOrder).sorted() })
  print("Two real cells prepared in",Date().timeIntervalSince(clock),"seconds")
  await session.load([a],collection:collection,store:store)
  precondition(session.cells.count == 1 && session.cells.first!.metadata.cellID == a.cellID)
  precondition(session.featureBounds.count == 1)
  let again = OfflineENCPackageSession()
  await again.load([a,b],collection:collection,store:store)
  precondition(again.cells.count == 2 && again.failures.isEmpty)
  let invalid = OfflineENCZip.CellCandidate(path:"BAD.000",cellID:"BAD",title:"Bad",bounds:nil)
  await again.load([invalid],collection:collection,store:store)
  precondition(again.cells.isEmpty && again.failures.count == 1)
  let canceled = Task { await again.load([a,b],collection:collection,store:store) }
  canceled.cancel(); await canceled.value
  precondition(again.cells.isEmpty)
  print("PASS: real cells, sorted portrayal, selection preserved, working set eviction, disk-cache reopen, invalid cell reporting, cancellation")
 }
}
