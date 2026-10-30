package com.nereus.anchorwatch.calculations

import com.nereus.anchorwatch.core.*
import kotlin.math.*

/** iOS robust outer-edge circle fit; timestamps are monotonic milliseconds. Never moves the marked anchor. */
object AnchorEstimate {
    enum class Method { FREE, FIXED_RADIUS }
    data class Estimate(val center: Coordinate, val semiMajor: Double, val semiMinor: Double, val majorBearing: Double,
        val method: Method, val radius: Double, val modelRadius: Double, val arc: Double, val pointsUsed: Int, val minutes: Double, val windAgrees: Boolean?)
    data class Evaluation(val estimate: Estimate? = null, val minutes: Double = 0.0, val uncertainty: Double? = null)
    data class FitResult(val center: ModelPoint, val radius: Double, val free: Boolean, val xx: Double, val xy: Double, val yy: Double)
    fun local(c: Coordinate, ref: Coordinate) = ModelPoint(Math.toRadians((c.longitude - ref.longitude + 540) % 360 - 180) * Geo.EARTH_RADIUS * cos(Math.toRadians(ref.latitude)), Math.toRadians(c.latitude - ref.latitude) * Geo.EARTH_RADIUS)
    fun coordinate(p: ModelPoint, ref: Coordinate): Coordinate {
        val latitude = ref.latitude + Math.toDegrees(p.y / Geo.EARTH_RADIUS)
        val longitude = ref.longitude + Math.toDegrees(p.x / (Geo.EARTH_RADIUS * cos(Math.toRadians(ref.latitude))))
        return Coordinate(latitude, (longitude + 540) % 360 - 180)
    }
    fun evaluate(track: List<Fix>, dropped: Long, mark: Coordinate, radius: Double, windFrom: Double?, windKnots: Double?, timeScale: Double = 1.0): Evaluation {
        val scale = max(timeScale, 1.0); val start = dropped + (2 * 60_000 / scale).toLong()
        val fixes = track.filter { it.time >= start }
        val minutes = max(0.0, ((fixes.lastOrNull()?.time ?: start) - start) * scale / 60_000)
        if (minutes < 20 || fixes.size < 30 || radius <= 0) return Evaluation(minutes = minutes)
        return fit(fixes, mark, radius, minutes, windFrom, windKnots, scale)
    }
    fun fit(fixes: List<Fix>, mark: Coordinate, radius: Double, minutes: Double, windFrom: Double? = null, windKnots: Double? = null, timeScale: Double = 1.0): Evaluation {
        if (fixes.size < 30 || !radius.isFinite() || radius <= 0) return Evaluation(minutes = minutes)
        val points = fixes.map { local(it.coordinate, mark) }
        var center = ModelPoint(0.0, 0.0); var fit: FitResult? = null; var edge = emptyList<ModelPoint>(); var arc = 0.0
        repeat(3) {
            val outer = outerEdge(points, center); edge = outer.first; arc = outer.second
            if (edge.size < 3) return@repeat
            val f = fitCircle(edge, center, radius, arc >= 90) ?: return@repeat
            fit = f; center = f.center
        }
        val f = fit ?: return Evaluation(minutes = minutes)
        if (!listOf(f.center.x, f.center.y, f.radius).all { it.isFinite() } || f.radius <= 0) return Evaluation(minutes = minutes)
        val slices = edge.map { slice(it, f.center) }.distinct().size
        val inflate = edge.size.toDouble() / max(slices, 1)
        var xx = f.xx * inflate; var xy = f.xy * inflate; var yy = f.yy * inflate
        if (!f.free) {
            val mx = edge.map { it.x }.average() - f.center.x; val my = edge.map { it.y }.average() - f.center.y
            val len = max(hypot(mx, my), 1e-6); val ux = mx / len; val uy = my / len; val v = (0.15 * radius).pow(2)
            xx += v * ux * ux; xy += v * ux * uy; yy += v * uy * uy
        }
        val axes = ellipse(xx, xy, yy)
        val major = max(axes.first, 2.0); val minor = max(axes.second, 2.0)
        if (major > 25) return Evaluation(minutes = minutes, uncertainty = major)
        var agrees: Boolean? = null
        if (windFrom != null && windKnots != null && windKnots >= 5) {
            val latest = fixes.last().time
            val recent = fixes.filter { latest - it.time <= 60_000 / max(timeScale, 1.0) }.map { local(it.coordinate, mark) }
            val wx = recent.map { it.x }.average() + f.radius * sin(Math.toRadians(windFrom))
            val wy = recent.map { it.y }.average() + f.radius * cos(Math.toRadians(windFrom))
            agrees = hypot(wx - f.center.x, wy - f.center.y) <= max(15.0, 2 * major)
        }
        return Evaluation(Estimate(coordinate(f.center, mark), major, minor, axes.third, if (f.free) Method.FREE else Method.FIXED_RADIUS,
            f.radius, radius, arc, edge.size, minutes, agrees), minutes)
    }
    fun slice(p: ModelPoint, c: ModelPoint) = (((Math.toDegrees(atan2(p.x - c.x, p.y - c.y)) + 360) % 360) / 10).toInt()
    fun outerEdge(points: List<ModelPoint>, center: ModelPoint): Pair<List<ModelPoint>, Double> {
        val slices = points.groupBy { slice(it, center) }
        val edge = slices.toSortedMap().values.flatMap { ps -> ps.sortedByDescending { hypot(it.x - center.x, it.y - center.y) }.take(max(1, ceil(ps.size * 0.2).toInt())) }
        val occupied = slices.keys.sorted(); var biggest = 0
        occupied.forEachIndexed { i, s -> val next = occupied.getOrNull(i + 1) ?: (occupied.first() + 36); biggest = max(biggest, next - s - 1) }
        return edge to if (occupied.isEmpty()) 0.0 else (36 - biggest) * 10.0
    }
    fun fitCircle(points: List<ModelPoint>, start: ModelPoint, radius: Double, free: Boolean): FitResult? {
        var cx = start.x; var cy = start.y; var r = radius; val n = if (free) 3 else 2
        if (points.size <= n) return null
        var normal = Array(n) { DoubleArray(n) }; var sigma2 = 1.0
        for (iteration in 0 until 30) {
            val distances = points.map { max(hypot(it.x - cx, it.y - cy), 1e-6) }
            val errors = distances.map { it - r }
            val mad = errors.map { abs(it) }.sorted()[errors.size / 2] * 1.4826; val k = 1.5 * max(mad, 0.5)
            val weights = errors.map { if (abs(it) <= k) 1.0 else k / abs(it) }
            normal = Array(n) { DoubleArray(n) }; val rhs = DoubleArray(n)
            points.indices.forEach { i ->
                val j = doubleArrayOf(-(points[i].x - cx) / distances[i], -(points[i].y - cy) / distances[i], -1.0)
                for (a in 0 until n) { rhs[a] -= weights[i] * j[a] * errors[i]; for (b in 0 until n) normal[a][b] += weights[i] * j[a] * j[b] }
            }
            val inverse = invert(normal) ?: return null
            val step = DoubleArray(n) { a -> (0 until n).sumOf { b -> inverse[a][b] * rhs[b] } }
            cx += step[0]; cy += step[1]; if (free) r += step[2]
            sigma2 = points.indices.sumOf { weights[it] * errors[it] * errors[it] } / max(points.size - n, 1)
            if (hypot(step[0], step[1]) < 0.001) break
        }
        val inv = invert(normal) ?: return null
        return FitResult(ModelPoint(cx, cy), r, free, sigma2 * inv[0][0], sigma2 * inv[0][1], sigma2 * inv[1][1])
    }
    fun ellipse(xx: Double, xy: Double, yy: Double): Triple<Double, Double, Double> {
        val mean = (xx + yy) / 2; val spread = sqrt(((xx - yy) / 2).pow(2) + xy * xy)
        val angle = 0.5 * atan2(2 * xy, xx - yy)
        return Triple(sqrt(max(mean + spread, 0.0)) * 1.51, sqrt(max(mean - spread, 0.0)) * 1.51, (90 - Math.toDegrees(angle) + 360) % 180)
    }
    fun invert(a: Array<DoubleArray>): Array<DoubleArray>? {
        val n = a.size; val m = Array(n) { i -> a[i].copyOf(2 * n).also { it[n + i] = 1.0 } }
        for (col in 0 until n) {
            val pivot = (col until n).maxBy { abs(m[it][col]) }
            if (abs(m[pivot][col]) <= 1e-12) return null
            val temp = m[col]; m[col] = m[pivot]; m[pivot] = temp
            val p = m[col][col]; for (j in 0 until 2 * n) m[col][j] /= p
            for (row in 0 until n) if (row != col) { val f = m[row][col]; for (j in 0 until 2 * n) m[row][j] -= f * m[col][j] }
        }
        return Array(n) { i -> m[i].copyOfRange(n, 2 * n) }
    }
}
