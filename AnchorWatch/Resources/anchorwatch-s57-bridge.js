(() => {
  // JavaScriptCore on iOS does not expose the browser's atob() global. The
  // bridge receives Base64 from Swift, so provide the small binary-string
  // behavior the decoder needs when running outside a browser.
  if (typeof globalThis.atob !== "function") {
    globalThis.atob = (value) => {
      const encoded = String(value);
      if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
        throw new Error("Invalid Base64 chart payload.");
      }
      const padding = encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0;
      const output = new Uint8Array(encoded.length / 4 * 3 - padding);
      const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      let outputIndex = 0;
      for (let index = 0; index < encoded.length; index += 4) {
        const a = alphabet.indexOf(encoded[index]);
        const b = alphabet.indexOf(encoded[index + 1]);
        const c = encoded[index + 2] === "=" ? 0 : alphabet.indexOf(encoded[index + 2]);
        const d = encoded[index + 3] === "=" ? 0 : alphabet.indexOf(encoded[index + 3]);
        output[outputIndex++] = (a << 2) | (b >> 4);
        if (encoded[index + 2] !== "=") output[outputIndex++] = ((b & 15) << 4) | (c >> 2);
        if (encoded[index + 3] !== "=") output[outputIndex++] = ((c & 3) << 6) | d;
      }
      let binary = "";
      for (let index = 0; index < output.length; index += 8192) {
        binary += String.fromCharCode.apply(null, output.subarray(index, index + 8192));
      }
      return binary;
    };
  }

  // packages/iso8211/dist/parser.js
  var UNIT_TERMINATOR = 31;
  var FIELD_TERMINATOR = 30;
  var LEADER_LENGTH = 24;
  function parse(buffer) {
    const view = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    let offset = 0;
    const ddr = parseRecord(bytes, view, offset);
    offset += ddr.leader.recordLength;
    const descriptors = buildDescriptors(ddr);
    const records = [];
    while (bytes.length - offset >= LEADER_LENGTH) {
      const dr = parseRecord(bytes, view, offset);
      decodeFields(dr, descriptors);
      records.push(dr);
      offset += dr.leader.recordLength;
    }
    return { ddr, records };
  }
  function parseRecord(bytes, view, offset) {
    if (bytes.length - offset < LEADER_LENGTH) {
      throw new Error(`ISO 8211: truncated record leader at byte ${offset}`);
    }
    const leader = parseLeader(bytes, offset);
    const { recordLength, baseAddressOfFieldArea, entryMap } = leader;
    if (!Number.isInteger(recordLength) || recordLength < LEADER_LENGTH || offset + recordLength > bytes.length) {
      throw new Error(`ISO 8211: invalid record length at byte ${offset}`);
    }
    if (!Number.isInteger(baseAddressOfFieldArea) || baseAddressOfFieldArea <= LEADER_LENGTH || baseAddressOfFieldArea > recordLength) {
      throw new Error(`ISO 8211: invalid base address of field area at byte ${offset}`);
    }
    if (!(entryMap.sizeOfFieldLength > 0 && entryMap.sizeOfFieldPosition > 0 && entryMap.sizeOfFieldTag > 0)) {
      throw new Error(`ISO 8211: invalid entry map at byte ${offset}`);
    }
    const directory = parseDirectory(bytes, offset, leader);
    const fields = extractFields(bytes, offset, leader, directory);
    return { leader, directory, fields };
  }
  function parseLeader(bytes, offset) {
    const ascii = (start, len) => String.fromCharCode(...bytes.slice(offset + start, offset + start + len));
    const num = (start, len) => parseInt(ascii(start, len), 10);
    return {
      recordLength: num(0, 5),
      interchangeLevel: ascii(5, 1),
      leaderIdentifier: ascii(6, 1),
      inlineCodeExtension: ascii(7, 1),
      versionNumber: ascii(8, 1),
      applicationIndicator: ascii(9, 1),
      fieldControlLength: num(10, 2),
      baseAddressOfFieldArea: num(12, 5),
      extendedCharSetIndicator: ascii(17, 3),
      entryMap: {
        sizeOfFieldLength: num(20, 1),
        sizeOfFieldPosition: num(21, 1),
        reserved: num(22, 1),
        sizeOfFieldTag: num(23, 1)
      }
    };
  }
  function parseDirectory(bytes, recordOffset, leader) {
    const { sizeOfFieldTag, sizeOfFieldLength, sizeOfFieldPosition } = leader.entryMap;
    const entrySize = sizeOfFieldTag + sizeOfFieldLength + sizeOfFieldPosition;
    const dirStart = recordOffset + 24;
    const dirEnd = recordOffset + leader.baseAddressOfFieldArea - 1;
    const dirLength = dirEnd - dirStart;
    const entryCount = Math.floor(dirLength / entrySize);
    const entries = [];
    for (let i = 0; i < entryCount; i++) {
      const pos = dirStart + i * entrySize;
      const ascii = (start, len) => String.fromCharCode(...bytes.slice(start, start + len));
      const tag = ascii(pos, sizeOfFieldTag);
      const length = parseInt(ascii(pos + sizeOfFieldTag, sizeOfFieldLength), 10);
      const position = parseInt(ascii(pos + sizeOfFieldTag + sizeOfFieldLength, sizeOfFieldPosition), 10);
      entries.push({ tag, length, position });
    }
    return entries;
  }
  function extractFields(bytes, recordOffset, leader, directory) {
    const baseAddr = recordOffset + leader.baseAddressOfFieldArea;
    return directory.map((entry) => {
      const fieldStart = baseAddr + entry.position;
      const raw = bytes.slice(fieldStart, fieldStart + entry.length);
      return {
        tag: entry.tag,
        raw,
        subfields: []
      };
    });
  }
  function buildDescriptors(ddr) {
    const map = /* @__PURE__ */ new Map();
    for (const field of ddr.fields) {
      if (field.tag === "0000")
        continue;
      const desc = parseDDRField(field);
      if (desc)
        map.set(desc.tag, desc);
    }
    return map;
  }
  function parseDDRField(field) {
    const raw = field.raw;
    const FIELD_CONTROLS_LEN = 6;
    let utPos1 = -1;
    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === UNIT_TERMINATOR) {
        utPos1 = i;
        break;
      }
    }
    if (utPos1 === -1)
      return null;
    let utPos2 = -1;
    for (let i = utPos1 + 1; i < raw.length; i++) {
      if (raw[i] === UNIT_TERMINATOR) {
        utPos2 = i;
        break;
      }
    }
    if (utPos2 === -1)
      return null;
    const fieldName = decodeASCII(raw, FIELD_CONTROLS_LEN, utPos1).trim();
    const labelsStr = decodeASCII(raw, utPos1 + 1, utPos2);
    const subfieldLabels = labelsStr.split("!").filter((s) => s.length > 0);
    const formatStr = decodeASCII(raw, utPos2 + 1, raw.length - 1);
    const formatControls = parseFormatControls(formatStr);
    return {
      tag: field.tag,
      fieldName,
      arrayDescriptor: "",
      formatControls,
      subfieldLabels
    };
  }
  function parseFormatControls(str) {
    const controls = [];
    let s = str.trim();
    if (s.startsWith("(") && s.endsWith(")")) {
      s = s.slice(1, -1);
    }
    if (!s)
      return controls;
    const tokens = s.split(",");
    for (const token of tokens) {
      const t = token.trim();
      if (!t)
        continue;
      const match = t.match(/^(\d*)([AIRBb])(?:\((\d+)\))?(\d*)$/i);
      if (match) {
        const repeat = parseInt(match[1] || "1", 10);
        const type = match[2];
        const width = parseInt(match[3] || match[4] || "0", 10);
        if (type === "b" || type === "B") {
          let signedness = 1;
          let byteWidth = 1;
          if (match[3]) {
            byteWidth = Math.ceil(parseInt(match[3], 10) / 8);
          } else if (match[4]) {
            const widthStr = match[4];
            signedness = widthStr.length >= 2 ? parseInt(widthStr[0], 10) : 1;
            byteWidth = widthStr.length >= 2 ? parseInt(widthStr.slice(1), 10) : parseInt(widthStr, 10);
          }
          for (let i = 0; i < repeat; i++) {
            controls.push({ type: "b", width: byteWidth, signedness });
          }
        } else {
          for (let i = 0; i < repeat; i++) {
            controls.push({ type, width });
          }
        }
      }
    }
    return controls;
  }
  function decodeFields(record, descriptors) {
    for (const field of record.fields) {
      const desc = descriptors.get(field.tag);
      if (!desc)
        continue;
      field.subfields = decodeSubfields(field.raw, desc);
    }
  }
  function decodeSubfields(raw, desc) {
    const values = [];
    let offset = 0;
    let formatIdx = 0;
    let labelIdx = 0;
    const limit = raw.length > 0 && raw[raw.length - 1] === FIELD_TERMINATOR ? raw.length - 1 : raw.length;
    while (offset < limit) {
      if (desc.formatControls.length === 0)
        break;
      const fmt = desc.formatControls[formatIdx % desc.formatControls.length];
      const label = desc.subfieldLabels[labelIdx % desc.subfieldLabels.length] || `field_${labelIdx}`;
      if (fmt.type === "A" || fmt.type === "a") {
        if (fmt.width > 0) {
          const end = Math.min(offset + fmt.width, raw.length);
          values.push({ type: "string", label, value: decodeASCII(raw, offset, end) });
          offset = end;
        } else {
          const end = findTerminator(raw, offset);
          values.push({ type: "string", label, value: decodeASCII(raw, offset, end) });
          offset = end + 1;
        }
      } else if (fmt.type === "I" || fmt.type === "i") {
        if (fmt.width > 0) {
          const end = Math.min(offset + fmt.width, raw.length);
          const str = decodeASCII(raw, offset, end).trim();
          values.push({ type: "int", label, value: parseInt(str, 10) || 0 });
          offset = end;
        } else {
          const end = findTerminator(raw, offset);
          const str = decodeASCII(raw, offset, end).trim();
          values.push({ type: "int", label, value: parseInt(str, 10) || 0 });
          offset = end + 1;
        }
      } else if (fmt.type === "R" || fmt.type === "r") {
        if (fmt.width > 0) {
          const end = Math.min(offset + fmt.width, raw.length);
          const str = decodeASCII(raw, offset, end).trim();
          values.push({ type: "real", label, value: parseFloat(str) || 0 });
          offset = end;
        } else {
          const end = findTerminator(raw, offset);
          const str = decodeASCII(raw, offset, end).trim();
          values.push({ type: "real", label, value: parseFloat(str) || 0 });
          offset = end + 1;
        }
      } else if (fmt.type === "b" || fmt.type === "B") {
        const byteWidth = fmt.width || 1;
        const end = Math.min(offset + byteWidth, raw.length);
        const chunk = raw.slice(offset, end);
        if (fmt.signedness === 2) {
          values.push({ type: "int", label, value: readSignedInt(chunk) });
        } else {
          values.push({ type: "uint", label, value: readUnsignedInt(chunk) });
        }
        offset = end;
      }
      formatIdx++;
      labelIdx++;
    }
    return values;
  }
  function findTerminator(raw, from) {
    for (let i = from; i < raw.length; i++) {
      if (raw[i] === UNIT_TERMINATOR || raw[i] === FIELD_TERMINATOR)
        return i;
    }
    return raw.length;
  }
  function decodeASCII(raw, start, end) {
    let s = "";
    for (let i = start; i < end; i++) {
      s += String.fromCharCode(raw[i]);
    }
    return s;
  }
  function readUnsignedInt(bytes) {
    let val = 0;
    for (let i = bytes.length - 1; i >= 0; i--) {
      val = val * 256 + bytes[i];
    }
    return val;
  }
  function readSignedInt(bytes) {
    const unsigned = readUnsignedInt(bytes);
    const bits = bytes.length * 8;
    const max = Math.pow(2, bits);
    const signBit = max / 2;
    if (unsigned >= signBit) {
      return unsigned - max;
    }
    return unsigned;
  }

  // packages/s57/src/text.ts
  var UT = 31;
  var FT = 30;
  var TextDecoderCtor = globalThis.TextDecoder;
  var decoders = /* @__PURE__ */ new Map();
  function decoder(encoding) {
    let d = decoders.get(encoding);
    if (!d) {
      if (!TextDecoderCtor) return null;
      try {
        d = new TextDecoderCtor(encoding);
      } catch {
        return null;
      }
      decoders.set(encoding, d);
    }
    return d;
  }
  var CP1251_HIGH = "\u0402\u0403\u201A\u0453\u201E\u2026\u2020\u2021\u20AC\u2030\u0409\u2039\u040A\u040C\u040B\u040F\u0452\u2018\u2019\u201C\u201D\u2022\u2013\u2014\uFFFD\u2122\u0459\u203A\u045A\u045C\u045B\u045F\xA0\u040E\u045E\u0408\xA4\u0490\xA6\xA7\u0401\xA9\u0404\xAB\xAC\xAD\xAE\u0407\xB0\xB1\u0406\u0456\u0491\xB5\xB6\xB7\u0451\u2116\u0454\xBB\u0458\u0405\u0455\u0457\u0410\u0411\u0412\u0413\u0414\u0415\u0416\u0417\u0418\u0419\u041A\u041B\u041C\u041D\u041E\u041F\u0420\u0421\u0422\u0423\u0424\u0425\u0426\u0427\u0428\u0429\u042A\u042B\u042C\u042D\u042E\u042F\u0430\u0431\u0432\u0433\u0434\u0435\u0436\u0437\u0438\u0439\u043A\u043B\u043C\u043D\u043E\u043F\u0440\u0441\u0442\u0443\u0444\u0445\u0446\u0447\u0448\u0449\u044A\u044B\u044C\u044D\u044E\u044F";
  var CP1250_HIGH = "\u20AC\uFFFD\u201A\uFFFD\u201E\u2026\u2020\u2021\uFFFD\u2030\u0160\u2039\u015A\u0164\u017D\u0179\uFFFD\u2018\u2019\u201C\u201D\u2022\u2013\u2014\uFFFD\u2122\u0161\u203A\u015B\u0165\u017E\u017A\xA0\u02C7\u02D8\u0141\xA4\u0104\xA6\xA7\xA8\xA9\u015E\xAB\xAC\xAD\xAE\u017B\xB0\xB1\u02DB\u0142\xB4\xB5\xB6\xB7\xB8\u0105\u015F\xBB\u013D\u02DD\u013E\u017C\u0154\xC1\xC2\u0102\xC4\u0139\u0106\xC7\u010C\xC9\u0118\xCB\u011A\xCD\xCE\u010E\u0110\u0143\u0147\xD3\xD4\u0150\xD6\xD7\u0158\u016E\xDA\u0170\xDC\xDD\u0162\xDF\u0155\xE1\xE2\u0103\xE4\u013A\u0107\xE7\u010D\xE9\u0119\xEB\u011B\xED\xEE\u010F\u0111\u0144\u0148\xF3\xF4\u0151\xF6\xF7\u0159\u016F\xFA\u0171\xFC\xFD\u0163\u02D9";
  function builtinTable(encoding) {
    if (/^(windows-1251|cp1251|x-cp1251)$/i.test(encoding)) return CP1251_HIGH;
    if (/^(windows-1250|cp1250|x-cp1250)$/i.test(encoding)) return CP1250_HIGH;
    return null;
  }
  function isLatin1(encoding) {
    return !encoding || /^(latin1|iso-8859-1|ascii|us-ascii)$/i.test(encoding);
  }
  function decode8bit(value, encoding) {
    if (isLatin1(encoding) || !/[\x80-\xff]/.test(value)) return value;
    const table = builtinTable(encoding);
    if (table) {
      let out = "";
      for (let i = 0; i < value.length; i++) {
        const c = value.charCodeAt(i) & 255;
        out += c < 128 ? value[i] : table[c - 128];
      }
      return out;
    }
    const d = decoder(encoding);
    if (!d) return value;
    const bytes = new Uint8Array(value.length);
    for (let i = 0; i < value.length; i++) bytes[i] = value.charCodeAt(i) & 255;
    return d.decode(bytes);
  }
  function readNatf(field, nall, encoding) {
    const raw = field.raw;
    const out = [];
    let i = 0;
    while (i + 2 <= raw.length) {
      if (raw[i] === FT && (nall !== 2 || i + 1 >= raw.length || raw[i + 1] === 0)) break;
      const attl = raw[i] | raw[i + 1] << 8;
      i += 2;
      let value = "";
      if (nall === 2) {
        const units = [];
        while (i + 1 < raw.length) {
          const u = raw[i] | raw[i + 1] << 8;
          i += 2;
          if (u === UT || u === FT) break;
          units.push(u);
        }
        value = String.fromCharCode(...units);
      } else {
        const start = i;
        while (i < raw.length && raw[i] !== UT && raw[i] !== FT) i++;
        let s = "";
        for (let k = start; k < i; k++) s += String.fromCharCode(raw[k]);
        value = decode8bit(s, encoding);
        if (i < raw.length && raw[i] === UT) i++;
      }
      out.push([attl, value]);
    }
    return out;
  }

  // packages/s57/src/parser.ts
  function parseS57(buffer, options = {}) {
    const textEncoding = options.textEncoding;
    const iso = parse(buffer);
    let name = "";
    let comf = 1e7;
    let somf = 10;
    let cscl;
    let nall;
    const features = [];
    const spatialRecords = /* @__PURE__ */ new Map();
    for (const rec of iso.records) {
      const fieldMap = buildFieldMap(rec.fields);
      const dsid = fieldMap.get("DSID");
      if (dsid) {
        name = getSubfieldStr(dsid, "DSNM") ?? name;
      }
      const dssi = fieldMap.get("DSSI");
      if (dssi) nall = getSubfieldNum(dssi, "NALL") ?? nall;
      const dspm = fieldMap.get("DSPM");
      if (dspm) {
        comf = getSubfieldNum(dspm, "COMF") ?? comf;
        somf = getSubfieldNum(dspm, "SOMF") ?? somf;
        cscl = getSubfieldNum(dspm, "CSCL") ?? cscl;
      }
      const vrid = fieldMap.get("VRID");
      if (vrid) {
        const spatial = parseSpatialRecord(vrid, fieldMap, comf, somf);
        if (spatial) spatialRecords.set(spatialKey(spatial.rcnm, spatial.rcid), spatial);
      }
      const frid = fieldMap.get("FRID");
      if (frid) {
        const feature = parseFeatureRecord(frid, fieldMap, nall ?? 1, textEncoding);
        if (feature) features.push(feature);
      }
    }
    return { name, comf, somf, cscl, nall, textEncoding, features, spatialRecords };
  }
  function buildFieldMap(fields) {
    const map = /* @__PURE__ */ new Map();
    for (const f of fields) {
      map.set(f.tag, f);
    }
    return map;
  }
  function parseSpatialRecord(vrid, fieldMap, comf, somf) {
    const rcnm = getSubfieldNum(vrid, "RCNM");
    const rcid = getSubfieldNum(vrid, "RCID");
    if (rcnm == null || rcid == null) return null;
    const coordinates2D = [];
    const coordinates3D = [];
    const sg2d = fieldMap.get("SG2D");
    if (sg2d) {
      const subfields2 = sg2d.subfields;
      for (let i = 0; i + 1 < subfields2.length; i += 2) {
        const ycoo = getNumericValue(subfields2[i]);
        const xcoo = getNumericValue(subfields2[i + 1]);
        if (ycoo != null && xcoo != null) {
          coordinates2D.push({
            lat: ycoo / comf,
            lon: xcoo / comf
          });
        }
      }
    }
    const sg3d = fieldMap.get("SG3D");
    if (sg3d) {
      const subfields2 = sg3d.subfields;
      for (let i = 0; i + 2 < subfields2.length; i += 3) {
        const ycoo = getNumericValue(subfields2[i]);
        const xcoo = getNumericValue(subfields2[i + 1]);
        const ve3d = getNumericValue(subfields2[i + 2]);
        if (ycoo != null && xcoo != null && ve3d != null) {
          coordinates3D.push({
            lat: ycoo / comf,
            lon: xcoo / comf,
            depth: ve3d / somf
          });
        }
      }
    }
    let startNodeRcid;
    let endNodeRcid;
    if (rcnm === 130 /* Edge */) {
      const vrpt = fieldMap.get("VRPT");
      if (vrpt) {
        const subfields2 = vrpt.subfields;
        for (let i = 0; i + 4 < subfields2.length; i += 5) {
          const namePacked = getNumericValue(subfields2[i]);
          const topi = getNumericValue(subfields2[i + 3]);
          if (namePacked != null && topi != null) {
            const nodeRcid = Math.floor(namePacked / 256);
            if (topi === 1) startNodeRcid = nodeRcid;
            if (topi === 2) endNodeRcid = nodeRcid;
          }
        }
      }
    }
    return {
      rcid,
      rcnm,
      coordinates2D,
      coordinates3D,
      startNodeRcid,
      endNodeRcid
    };
  }
  function parseFeatureRecord(frid, fieldMap, nall, textEncoding) {
    const rcid = getSubfieldNum(frid, "RCID");
    const objl = getSubfieldNum(frid, "OBJL");
    const prim = getSubfieldNum(frid, "PRIM");
    const grup = getSubfieldNum(frid, "GRUP");
    if (rcid == null || objl == null || prim == null) return null;
    const attributes = /* @__PURE__ */ new Map();
    const attf = fieldMap.get("ATTF");
    if (attf) {
      const subfields2 = attf.subfields;
      for (let i = 0; i + 1 < subfields2.length; i += 2) {
        const attl = getNumericValue(subfields2[i]);
        const atvl = subfields2[i + 1];
        if (attl != null && atvl) {
          attributes.set(attl, atvl.type === "string" ? decode8bit(atvl.value, textEncoding) : String(atvl.value));
        }
      }
    }
    const natf = fieldMap.get("NATF");
    if (natf) for (const [attl, value] of readNatf(natf, nall, textEncoding)) attributes.set(attl, value);
    const spatialRefs = [];
    const fspt = fieldMap.get("FSPT");
    if (fspt) {
      const subfields2 = fspt.subfields;
      for (let i = 0; i + 3 < subfields2.length; i += 4) {
        const namePacked = getNumericValue(subfields2[i]);
        const ornt = getNumericValue(subfields2[i + 1]) ?? 255;
        const usag = getNumericValue(subfields2[i + 2]) ?? 255;
        const mask = getNumericValue(subfields2[i + 3]) ?? 255;
        if (namePacked != null) {
          const rcnmVal = namePacked & 255;
          const rcidVal = Math.floor(namePacked / 256) & 4294967295;
          spatialRefs.push({ rcnm: rcnmVal, rcid: rcidVal, ornt, usag, mask });
        }
      }
    }
    let foid;
    const foidField = fieldMap.get("FOID");
    if (foidField) {
      const agen = getSubfieldNum(foidField, "AGEN");
      const fidn = getSubfieldNum(foidField, "FIDN");
      const fids = getSubfieldNum(foidField, "FIDS");
      if (agen != null && fidn != null && fids != null) {
        foid = { agen, fidn, fids };
      }
    }
    return {
      rcid,
      objl,
      prim: prim ?? 255 /* None */,
      grup: grup ?? 0,
      attributes,
      spatialRefs,
      foid
    };
  }
  function spatialKey(rcnm, rcid) {
    return rcnm * 1e5 + rcid;
  }
  function getSubfieldStr(field, label) {
    const sf = field.subfields.find((s) => s.label === label);
    if (!sf) return void 0;
    return sf.type === "string" ? sf.value : String(sf.value);
  }
  function getSubfieldNum(field, label) {
    const sf = field.subfields.find((s) => s.label === label);
    if (!sf) return void 0;
    return getNumericValue(sf);
  }
  function getNumericValue(sf) {
    if (!sf) return void 0;
    if (sf.type === "int" || sf.type === "uint" || sf.type === "real") return sf.value;
    if (sf.type === "string") {
      const n = parseFloat(sf.value);
      return isNaN(n) ? void 0 : n;
    }
    return void 0;
  }

  // packages/s57/src/geojson.ts
  function toGeoJSON(dataset, objlFilter) {
    const features = [];
    for (const feature of dataset.features) {
      if (objlFilter && !objlFilter.includes(feature.objl)) continue;
      const geometry = resolveGeometry(feature, dataset.spatialRecords);
      const properties = buildProperties(feature);
      if (feature.prim === 3 /* Area */ && geometry) {
        const outline = areaOutline(feature, dataset.spatialRecords);
        if (outline) properties._outline = outline;
      }
      features.push({ type: "Feature", geometry, properties });
    }
    return { type: "FeatureCollection", features };
  }
  function resolveGeometry(feature, spatialRecords) {
    if (feature.prim === 255 /* None */ || feature.spatialRefs.length === 0) {
      return null;
    }
    if (feature.prim === 1 /* Point */) {
      return resolvePoint(feature, spatialRecords);
    }
    if (feature.prim === 2 /* Line */) {
      return resolveLine(feature, spatialRecords);
    }
    if (feature.prim === 3 /* Area */) {
      return resolveArea(feature, spatialRecords);
    }
    return null;
  }
  function resolvePoint(feature, spatialRecords) {
    const allCoords = [];
    for (const ref of feature.spatialRefs) {
      const spatial = spatialRecords.get(spatialKey(ref.rcnm, ref.rcid));
      if (!spatial) continue;
      if (spatial.coordinates2D.length > 0) {
        for (const c of spatial.coordinates2D) {
          allCoords.push([c.lon, c.lat]);
        }
      } else if (spatial.coordinates3D.length > 0) {
        for (const c of spatial.coordinates3D) {
          allCoords.push([c.lon, c.lat]);
        }
      }
    }
    if (allCoords.length === 0) return null;
    if (allCoords.length === 1) return { type: "Point", coordinates: allCoords[0] };
    return { type: "MultiPoint", coordinates: allCoords };
  }
  function resolveLine(feature, spatialRecords) {
    const coords = [];
    for (const ref of feature.spatialRefs) {
      const spatial = spatialRecords.get(spatialKey(ref.rcnm, ref.rcid));
      if (!spatial) continue;
      const edgeCoords = coordsFromSpatial(spatial, spatialRecords);
      if (ref.ornt === 2) edgeCoords.reverse();
      if (coords.length > 0 && edgeCoords.length > 0) {
        const last = coords[coords.length - 1];
        const first = edgeCoords[0];
        if (last[0] === first[0] && last[1] === first[1]) {
          edgeCoords.shift();
        }
      }
      coords.push(...edgeCoords);
    }
    if (coords.length < 2) return null;
    return { type: "LineString", coordinates: coords };
  }
  function resolveArea(feature, spatialRecords) {
    const exteriorCoords = [];
    const interiorRings = [];
    let hole = [];
    for (const ref of feature.spatialRefs) {
      const spatial = spatialRecords.get(spatialKey(ref.rcnm, ref.rcid));
      if (!spatial) continue;
      const edgeCoords = coordsFromSpatial(spatial, spatialRecords);
      if (ref.ornt === 2) edgeCoords.reverse();
      if (ref.usag === 2) {
        appendEdge(hole, edgeCoords);
        if (hole.length >= 4 && samePoint(hole[0], hole[hole.length - 1])) {
          interiorRings.push(hole);
          hole = [];
        }
      } else {
        if (exteriorCoords.length > 0 && edgeCoords.length > 0) {
          const last = exteriorCoords[exteriorCoords.length - 1];
          const first = edgeCoords[0];
          if (last[0] === first[0] && last[1] === first[1]) {
            edgeCoords.shift();
          }
        }
        exteriorCoords.push(...edgeCoords);
      }
    }
    if (hole.length >= 3) interiorRings.push(closeRing(hole));
    if (exteriorCoords.length < 3) return null;
    const rings = [closeRing(exteriorCoords), ...interiorRings];
    return { type: "Polygon", coordinates: rings };
  }
  function areaOutline(feature, spatialRecords) {
    if (!feature.spatialRefs.some((r) => r.usag === 3 || r.mask === 1)) return void 0;
    const lines = [];
    let current = [];
    for (const ref of feature.spatialRefs) {
      const spatial = spatialRecords.get(spatialKey(ref.rcnm, ref.rcid));
      if (!spatial) continue;
      if (ref.usag === 3 || ref.mask === 1) {
        if (current.length >= 2) lines.push(current);
        current = [];
        continue;
      }
      const edgeCoords = coordsFromSpatial(spatial, spatialRecords);
      if (ref.ornt === 2) edgeCoords.reverse();
      if (current.length && edgeCoords.length && !samePoint(current[current.length - 1], edgeCoords[0])) {
        if (current.length >= 2) lines.push(current);
        current = [];
      }
      appendEdge(current, edgeCoords);
    }
    if (current.length >= 2) lines.push(current);
    return lines;
  }
  function appendEdge(chain, edge) {
    if (chain.length && edge.length && samePoint(chain[chain.length - 1], edge[0])) {
      chain.push(...edge.slice(1));
    } else {
      chain.push(...edge);
    }
  }
  function samePoint(a, b) {
    return a[0] === b[0] && a[1] === b[1];
  }
  function coordsFromSpatial(spatial, spatialRecords) {
    const intermediate = spatial.coordinates2D.length > 0 ? spatial.coordinates2D.map((c) => [c.lon, c.lat]) : spatial.coordinates3D.map((c) => [c.lon, c.lat]);
    if (spatial.rcnm !== 130 /* Edge */) return intermediate;
    const startNode = spatial.startNodeRcid != null ? spatialRecords.get(spatialKey(120 /* ConnectedNode */, spatial.startNodeRcid)) : void 0;
    const endNode = spatial.endNodeRcid != null ? spatialRecords.get(spatialKey(120 /* ConnectedNode */, spatial.endNodeRcid)) : void 0;
    const startCoord = startNode?.coordinates2D[0];
    const endCoord = endNode?.coordinates2D[0];
    const coords = [...intermediate];
    if (startCoord) coords.unshift([startCoord.lon, startCoord.lat]);
    if (endCoord) coords.push([endCoord.lon, endCoord.lat]);
    return coords;
  }
  function closeRing(coords) {
    if (coords.length < 2) return coords;
    const first = coords[0];
    const last = coords[coords.length - 1];
    if (first[0] !== last[0] || first[1] !== last[1]) {
      return [...coords, first];
    }
    return coords;
  }
  function buildProperties(feature) {
    const props = {
      RCID: feature.rcid,
      OBJL: feature.objl,
      PRIM: feature.prim,
      GRUP: feature.grup
    };
    for (const [code, value] of feature.attributes) {
      props[`ATTL_${code}`] = value;
    }
    if (feature.foid) {
      props.AGEN = feature.foid.agen;
      props.FIDN = feature.foid.fidn;
      props.FIDS = feature.foid.fids;
    }
    return props;
  }

  // packages/s57/src/update.ts
  var RUIN_INSERT = 1;
  var RUIN_DELETE = 2;
  var RUIN_MODIFY = 3;
  function applyUpdate(dataset, updateBuffer) {
    const iso = parse(updateBuffer);
    for (const rec of iso.records) {
      const fieldMap = buildFieldMap2(rec.fields);
      const dsid = fieldMap.get("DSID");
      if (dsid) {
        const dsnm = getSubfieldStr2(dsid, "DSNM");
        if (dsnm) dataset.name = dsnm;
      }
      const dspm = fieldMap.get("DSPM");
      if (dspm) {
        const comf = getSubfieldNum2(dspm, "COMF");
        const somf = getSubfieldNum2(dspm, "SOMF");
        if (comf != null) dataset.comf = comf;
        if (somf != null) dataset.somf = somf;
      }
      const vrid = fieldMap.get("VRID");
      if (vrid) {
        applySpatialUpdate(dataset, vrid, fieldMap);
      }
      const frid = fieldMap.get("FRID");
      if (frid) {
        applyFeatureUpdate(dataset, frid, fieldMap);
      }
    }
    return dataset;
  }
  function applySpatialUpdate(dataset, vrid, fieldMap) {
    const rcnm = getSubfieldNum2(vrid, "RCNM");
    const rcid = getSubfieldNum2(vrid, "RCID");
    const ruin = getSubfieldNum2(vrid, "RUIN") ?? 0;
    if (rcnm == null || rcid == null) return;
    const key = spatialKey(rcnm, rcid);
    if (ruin === RUIN_INSERT) {
      const spatial = buildSpatialFromFields(rcnm, rcid, fieldMap, dataset.comf, dataset.somf);
      if (spatial) dataset.spatialRecords.set(key, spatial);
      return;
    }
    if (ruin === RUIN_DELETE) {
      dataset.spatialRecords.delete(key);
      return;
    }
    if (ruin === RUIN_MODIFY) {
      const existing = dataset.spatialRecords.get(key);
      if (!existing) return;
      const sgcc = fieldMap.get("SGCC");
      if (sgcc) {
        const ccui = getSubfieldNum2(sgcc, "CCUI") ?? 0;
        const ccix = (getSubfieldNum2(sgcc, "CCIX") ?? 1) - 1;
        const ccnc = getSubfieldNum2(sgcc, "CCNC") ?? 0;
        const sg2d = fieldMap.get("SG2D");
        const sg3d = fieldMap.get("SG3D");
        if (sg3d || !sg2d && existing.coordinates3D.length > 0) {
          const newCoords = sg3d ? parse3DCoords(sg3d, dataset.comf, dataset.somf) : [];
          applySplice(existing.coordinates3D, ccui, ccix, ccnc, newCoords);
        } else {
          const newCoords = sg2d ? parse2DCoords(sg2d, dataset.comf) : [];
          applySplice(existing.coordinates2D, ccui, ccix, ccnc, newCoords);
        }
      }
      const vrpc = fieldMap.get("VRPC");
      const vrpt = fieldMap.get("VRPT");
      if (vrpc && vrpt) {
        const vpui = getSubfieldNum2(vrpc, "VPUI") ?? 0;
        const vpix = (getSubfieldNum2(vrpc, "VPIX") ?? 1) - 1;
        const nvpt = getSubfieldNum2(vrpc, "NVPT") ?? 0;
        const subfields2 = vrpt.subfields;
        for (let i = 0; i + 4 < subfields2.length; i += 5) {
          const namePacked = getNumericValue2(subfields2[i]);
          const topi = getNumericValue2(subfields2[i + 3]);
          if (namePacked != null && topi != null) {
            const nodeRcid = Math.floor(namePacked / 256);
            if (topi === 1) existing.startNodeRcid = nodeRcid;
            if (topi === 2) existing.endNodeRcid = nodeRcid;
          }
        }
      }
    }
  }
  function applyFeatureUpdate(dataset, frid, fieldMap) {
    const rcid = getSubfieldNum2(frid, "RCID");
    const ruin = getSubfieldNum2(frid, "RUIN") ?? 0;
    if (rcid == null) return;
    if (ruin === RUIN_INSERT) {
      const feature = buildFeatureFromFields(frid, fieldMap, dataset);
      if (feature) dataset.features.push(feature);
      return;
    }
    const idx = dataset.features.findIndex((f) => f.rcid === rcid);
    if (idx === -1) return;
    if (ruin === RUIN_DELETE) {
      dataset.features.splice(idx, 1);
      return;
    }
    if (ruin === RUIN_MODIFY) {
      const existing = dataset.features[idx];
      const objl = getSubfieldNum2(frid, "OBJL");
      const prim = getSubfieldNum2(frid, "PRIM");
      const grup = getSubfieldNum2(frid, "GRUP");
      if (objl != null) existing.objl = objl;
      if (prim != null) existing.prim = prim;
      if (grup != null) existing.grup = grup;
      const attf = fieldMap.get("ATTF");
      if (attf) {
        const subfields2 = attf.subfields;
        for (let i = 0; i + 1 < subfields2.length; i += 2) {
          const attl = getNumericValue2(subfields2[i]);
          const atvl = subfields2[i + 1];
          if (attl != null && atvl) {
            const val = atvl.type === "string" ? decode8bit(atvl.value, dataset.textEncoding) : String(atvl.value);
            if (val === "" || val === "\x7F") {
              existing.attributes.delete(attl);
            } else {
              existing.attributes.set(attl, val);
            }
          }
        }
      }
      const natf = fieldMap.get("NATF");
      if (natf) {
        for (const [attl, val] of readNatf(natf, dataset.nall ?? 1, dataset.textEncoding)) {
          if (val === "" || val === "\x7F") existing.attributes.delete(attl);
          else existing.attributes.set(attl, val);
        }
      }
      const fspc = fieldMap.get("FSPC");
      const fspt = fieldMap.get("FSPT");
      if (fspc) {
        const fsui = getSubfieldNum2(fspc, "FSUI") ?? 0;
        const fsix = (getSubfieldNum2(fspc, "FSIX") ?? 1) - 1;
        const nspt = getSubfieldNum2(fspc, "NSPT") ?? 0;
        const newRefs = fspt ? parseSpatialRefs(fspt) : [];
        applySplice(existing.spatialRefs, fsui, fsix, nspt, newRefs);
      }
      const foidField = fieldMap.get("FOID");
      if (foidField) {
        const agen = getSubfieldNum2(foidField, "AGEN");
        const fidn = getSubfieldNum2(foidField, "FIDN");
        const fids = getSubfieldNum2(foidField, "FIDS");
        if (agen != null && fidn != null && fids != null) {
          existing.foid = { agen, fidn, fids };
        }
      }
    }
  }
  function buildFieldMap2(fields) {
    const map = /* @__PURE__ */ new Map();
    for (const f of fields) map.set(f.tag, f);
    return map;
  }
  function applySplice(arr, instruction, index, count, items) {
    if (instruction === 1) {
      arr.splice(index, 0, ...items);
    } else if (instruction === 2) {
      arr.splice(index, count);
    } else if (instruction === 3) {
      arr.splice(index, count, ...items);
    }
  }
  function buildSpatialFromFields(rcnm, rcid, fieldMap, comf, somf) {
    const coordinates2D = [];
    const coordinates3D = [];
    const sg2d = fieldMap.get("SG2D");
    if (sg2d) coordinates2D.push(...parse2DCoords(sg2d, comf));
    const sg3d = fieldMap.get("SG3D");
    if (sg3d) coordinates3D.push(...parse3DCoords(sg3d, comf, somf));
    let startNodeRcid;
    let endNodeRcid;
    if (rcnm === 130 /* Edge */) {
      const vrpt = fieldMap.get("VRPT");
      if (vrpt) {
        const subfields2 = vrpt.subfields;
        for (let i = 0; i + 4 < subfields2.length; i += 5) {
          const namePacked = getNumericValue2(subfields2[i]);
          const topi = getNumericValue2(subfields2[i + 3]);
          if (namePacked != null && topi != null) {
            const nodeRcid = Math.floor(namePacked / 256);
            if (topi === 1) startNodeRcid = nodeRcid;
            if (topi === 2) endNodeRcid = nodeRcid;
          }
        }
      }
    }
    return { rcid, rcnm, coordinates2D, coordinates3D, startNodeRcid, endNodeRcid };
  }
  function buildFeatureFromFields(frid, fieldMap, dataset) {
    const rcid = getSubfieldNum2(frid, "RCID");
    const objl = getSubfieldNum2(frid, "OBJL");
    const prim = getSubfieldNum2(frid, "PRIM");
    const grup = getSubfieldNum2(frid, "GRUP");
    if (rcid == null || objl == null || prim == null) return null;
    const attributes = /* @__PURE__ */ new Map();
    const attf = fieldMap.get("ATTF");
    if (attf) {
      const subfields2 = attf.subfields;
      for (let i = 0; i + 1 < subfields2.length; i += 2) {
        const attl = getNumericValue2(subfields2[i]);
        const atvl = subfields2[i + 1];
        if (attl != null && atvl) {
          attributes.set(attl, atvl.type === "string" ? decode8bit(atvl.value, dataset.textEncoding) : String(atvl.value));
        }
      }
    }
    const natf = fieldMap.get("NATF");
    if (natf) for (const [attl, val] of readNatf(natf, dataset.nall ?? 1, dataset.textEncoding)) attributes.set(attl, val);
    const fspt = fieldMap.get("FSPT");
    const spatialRefs = fspt ? parseSpatialRefs(fspt) : [];
    let foid;
    const foidField = fieldMap.get("FOID");
    if (foidField) {
      const agen = getSubfieldNum2(foidField, "AGEN");
      const fidn = getSubfieldNum2(foidField, "FIDN");
      const fids = getSubfieldNum2(foidField, "FIDS");
      if (agen != null && fidn != null && fids != null) foid = { agen, fidn, fids };
    }
    return {
      rcid,
      objl,
      prim: prim ?? 255 /* None */,
      grup: grup ?? 0,
      attributes,
      spatialRefs,
      foid
    };
  }
  function parseSpatialRefs(fspt) {
    const refs = [];
    const subfields2 = fspt.subfields;
    for (let i = 0; i + 3 < subfields2.length; i += 4) {
      const namePacked = getNumericValue2(subfields2[i]);
      const ornt = getNumericValue2(subfields2[i + 1]) ?? 255;
      const usag = getNumericValue2(subfields2[i + 2]) ?? 255;
      const mask = getNumericValue2(subfields2[i + 3]) ?? 255;
      if (namePacked != null) {
        const rcnmVal = namePacked & 255;
        const rcidVal = Math.floor(namePacked / 256) & 4294967295;
        refs.push({ rcnm: rcnmVal, rcid: rcidVal, ornt, usag, mask });
      }
    }
    return refs;
  }
  function parse2DCoords(sg2d, comf) {
    const coords = [];
    const subfields2 = sg2d.subfields;
    for (let i = 0; i + 1 < subfields2.length; i += 2) {
      const ycoo = getNumericValue2(subfields2[i]);
      const xcoo = getNumericValue2(subfields2[i + 1]);
      if (ycoo != null && xcoo != null) {
        coords.push({ lat: ycoo / comf, lon: xcoo / comf });
      }
    }
    return coords;
  }
  function parse3DCoords(sg3d, comf, somf) {
    const coords = [];
    const subfields2 = sg3d.subfields;
    for (let i = 0; i + 2 < subfields2.length; i += 3) {
      const ycoo = getNumericValue2(subfields2[i]);
      const xcoo = getNumericValue2(subfields2[i + 1]);
      const ve3d = getNumericValue2(subfields2[i + 2]);
      if (ycoo != null && xcoo != null && ve3d != null) {
        coords.push({ lat: ycoo / comf, lon: xcoo / comf, depth: ve3d / somf });
      }
    }
    return coords;
  }
  function getSubfieldStr2(field, label) {
    const sf = field.subfields.find((s) => s.label === label);
    if (!sf) return void 0;
    return sf.type === "string" ? sf.value : String(sf.value);
  }
  function getSubfieldNum2(field, label) {
    const sf = field.subfields.find((s) => s.label === label);
    if (!sf) return void 0;
    return getNumericValue2(sf);
  }
  function getNumericValue2(sf) {
    if (!sf) return void 0;
    if (sf.type === "int" || sf.type === "uint" || sf.type === "real") return sf.value;
    if (sf.type === "string") {
      const n = parseFloat(sf.value);
      return isNaN(n) ? void 0 : n;
    }
    return void 0;
  }

  // packages/iso8211/src/parser.ts
  var UNIT_TERMINATOR2 = 31;
  var FIELD_TERMINATOR2 = 30;
  var LEADER_LENGTH2 = 24;
  function parse2(buffer) {
    const view = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    let offset = 0;
    const ddr = parseRecord2(bytes, view, offset);
    offset += ddr.leader.recordLength;
    const descriptors = buildDescriptors2(ddr);
    const records = [];
    while (bytes.length - offset >= LEADER_LENGTH2) {
      const dr = parseRecord2(bytes, view, offset);
      decodeFields2(dr, descriptors);
      records.push(dr);
      offset += dr.leader.recordLength;
    }
    return { ddr, records };
  }
  function parseRecord2(bytes, view, offset) {
    if (bytes.length - offset < LEADER_LENGTH2) {
      throw new Error(`ISO 8211: truncated record leader at byte ${offset}`);
    }
    const leader = parseLeader2(bytes, offset);
    const { recordLength, baseAddressOfFieldArea, entryMap } = leader;
    if (!Number.isInteger(recordLength) || recordLength < LEADER_LENGTH2 || offset + recordLength > bytes.length) {
      throw new Error(`ISO 8211: invalid record length at byte ${offset}`);
    }
    if (!Number.isInteger(baseAddressOfFieldArea) || baseAddressOfFieldArea <= LEADER_LENGTH2 || baseAddressOfFieldArea > recordLength) {
      throw new Error(`ISO 8211: invalid base address of field area at byte ${offset}`);
    }
    if (!(entryMap.sizeOfFieldLength > 0 && entryMap.sizeOfFieldPosition > 0 && entryMap.sizeOfFieldTag > 0)) {
      throw new Error(`ISO 8211: invalid entry map at byte ${offset}`);
    }
    const directory = parseDirectory2(bytes, offset, leader);
    const fields = extractFields2(bytes, offset, leader, directory);
    return { leader, directory, fields };
  }
  function parseLeader2(bytes, offset) {
    const ascii = (start, len) => String.fromCharCode(...bytes.slice(offset + start, offset + start + len));
    const num = (start, len) => parseInt(ascii(start, len), 10);
    return {
      recordLength: num(0, 5),
      interchangeLevel: ascii(5, 1),
      leaderIdentifier: ascii(6, 1),
      inlineCodeExtension: ascii(7, 1),
      versionNumber: ascii(8, 1),
      applicationIndicator: ascii(9, 1),
      fieldControlLength: num(10, 2),
      baseAddressOfFieldArea: num(12, 5),
      extendedCharSetIndicator: ascii(17, 3),
      entryMap: {
        sizeOfFieldLength: num(20, 1),
        sizeOfFieldPosition: num(21, 1),
        reserved: num(22, 1),
        sizeOfFieldTag: num(23, 1)
      }
    };
  }
  function parseDirectory2(bytes, recordOffset, leader) {
    const { sizeOfFieldTag, sizeOfFieldLength, sizeOfFieldPosition } = leader.entryMap;
    const entrySize = sizeOfFieldTag + sizeOfFieldLength + sizeOfFieldPosition;
    const dirStart = recordOffset + 24;
    const dirEnd = recordOffset + leader.baseAddressOfFieldArea - 1;
    const dirLength = dirEnd - dirStart;
    const entryCount = Math.floor(dirLength / entrySize);
    const entries = [];
    for (let i = 0; i < entryCount; i++) {
      const pos = dirStart + i * entrySize;
      const ascii = (start, len) => String.fromCharCode(...bytes.slice(start, start + len));
      const tag = ascii(pos, sizeOfFieldTag);
      const length = parseInt(ascii(pos + sizeOfFieldTag, sizeOfFieldLength), 10);
      const position = parseInt(ascii(pos + sizeOfFieldTag + sizeOfFieldLength, sizeOfFieldPosition), 10);
      entries.push({ tag, length, position });
    }
    return entries;
  }
  function extractFields2(bytes, recordOffset, leader, directory) {
    const baseAddr = recordOffset + leader.baseAddressOfFieldArea;
    return directory.map((entry) => {
      const fieldStart = baseAddr + entry.position;
      const raw = bytes.slice(fieldStart, fieldStart + entry.length);
      return {
        tag: entry.tag,
        raw,
        subfields: []
      };
    });
  }
  function buildDescriptors2(ddr) {
    const map = /* @__PURE__ */ new Map();
    for (const field of ddr.fields) {
      if (field.tag === "0000") continue;
      const desc = parseDDRField2(field);
      if (desc) map.set(desc.tag, desc);
    }
    return map;
  }
  function parseDDRField2(field) {
    const raw = field.raw;
    const FIELD_CONTROLS_LEN = 6;
    let utPos1 = -1;
    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === UNIT_TERMINATOR2) {
        utPos1 = i;
        break;
      }
    }
    if (utPos1 === -1) return null;
    let utPos2 = -1;
    for (let i = utPos1 + 1; i < raw.length; i++) {
      if (raw[i] === UNIT_TERMINATOR2) {
        utPos2 = i;
        break;
      }
    }
    if (utPos2 === -1) return null;
    const fieldName = decodeASCII2(raw, FIELD_CONTROLS_LEN, utPos1).trim();
    const labelsStr = decodeASCII2(raw, utPos1 + 1, utPos2);
    const subfieldLabels = labelsStr.split("!").filter((s) => s.length > 0);
    const formatStr = decodeASCII2(raw, utPos2 + 1, raw.length - 1);
    const formatControls = parseFormatControls2(formatStr);
    return {
      tag: field.tag,
      fieldName,
      arrayDescriptor: "",
      formatControls,
      subfieldLabels
    };
  }
  function parseFormatControls2(str) {
    const controls = [];
    let s = str.trim();
    if (s.startsWith("(") && s.endsWith(")")) {
      s = s.slice(1, -1);
    }
    if (!s) return controls;
    const tokens = s.split(",");
    for (const token of tokens) {
      const t = token.trim();
      if (!t) continue;
      const match = t.match(/^(\d*)([AIRBb])(?:\((\d+)\))?(\d*)$/i);
      if (match) {
        const repeat = parseInt(match[1] || "1", 10);
        const type = match[2];
        const width = parseInt(match[3] || match[4] || "0", 10);
        if (type === "b" || type === "B") {
          let signedness = 1;
          let byteWidth = 1;
          if (match[3]) {
            byteWidth = Math.ceil(parseInt(match[3], 10) / 8);
          } else if (match[4]) {
            const widthStr = match[4];
            signedness = widthStr.length >= 2 ? parseInt(widthStr[0], 10) : 1;
            byteWidth = widthStr.length >= 2 ? parseInt(widthStr.slice(1), 10) : parseInt(widthStr, 10);
          }
          for (let i = 0; i < repeat; i++) {
            controls.push({ type: "b", width: byteWidth, signedness });
          }
        } else {
          for (let i = 0; i < repeat; i++) {
            controls.push({ type, width });
          }
        }
      }
    }
    return controls;
  }
  function decodeFields2(record, descriptors) {
    for (const field of record.fields) {
      const desc = descriptors.get(field.tag);
      if (!desc) continue;
      field.subfields = decodeSubfields2(field.raw, desc);
    }
  }
  function decodeSubfields2(raw, desc) {
    const values = [];
    let offset = 0;
    let formatIdx = 0;
    let labelIdx = 0;
    const limit = raw.length > 0 && raw[raw.length - 1] === FIELD_TERMINATOR2 ? raw.length - 1 : raw.length;
    while (offset < limit) {
      if (desc.formatControls.length === 0) break;
      const fmt = desc.formatControls[formatIdx % desc.formatControls.length];
      const label = desc.subfieldLabels[labelIdx % desc.subfieldLabels.length] || `field_${labelIdx}`;
      if (fmt.type === "A" || fmt.type === "a") {
        if (fmt.width > 0) {
          const end = Math.min(offset + fmt.width, raw.length);
          values.push({ type: "string", label, value: decodeASCII2(raw, offset, end) });
          offset = end;
        } else {
          const end = findTerminator2(raw, offset);
          values.push({ type: "string", label, value: decodeASCII2(raw, offset, end) });
          offset = end + 1;
        }
      } else if (fmt.type === "I" || fmt.type === "i") {
        if (fmt.width > 0) {
          const end = Math.min(offset + fmt.width, raw.length);
          const str = decodeASCII2(raw, offset, end).trim();
          values.push({ type: "int", label, value: parseInt(str, 10) || 0 });
          offset = end;
        } else {
          const end = findTerminator2(raw, offset);
          const str = decodeASCII2(raw, offset, end).trim();
          values.push({ type: "int", label, value: parseInt(str, 10) || 0 });
          offset = end + 1;
        }
      } else if (fmt.type === "R" || fmt.type === "r") {
        if (fmt.width > 0) {
          const end = Math.min(offset + fmt.width, raw.length);
          const str = decodeASCII2(raw, offset, end).trim();
          values.push({ type: "real", label, value: parseFloat(str) || 0 });
          offset = end;
        } else {
          const end = findTerminator2(raw, offset);
          const str = decodeASCII2(raw, offset, end).trim();
          values.push({ type: "real", label, value: parseFloat(str) || 0 });
          offset = end + 1;
        }
      } else if (fmt.type === "b" || fmt.type === "B") {
        const byteWidth = fmt.width || 1;
        const end = Math.min(offset + byteWidth, raw.length);
        const chunk = raw.slice(offset, end);
        if (fmt.signedness === 2) {
          values.push({ type: "int", label, value: readSignedInt2(chunk) });
        } else {
          values.push({ type: "uint", label, value: readUnsignedInt2(chunk) });
        }
        offset = end;
      }
      formatIdx++;
      labelIdx++;
    }
    return values;
  }
  function findTerminator2(raw, from) {
    for (let i = from; i < raw.length; i++) {
      if (raw[i] === UNIT_TERMINATOR2 || raw[i] === FIELD_TERMINATOR2) return i;
    }
    return raw.length;
  }
  function decodeASCII2(raw, start, end) {
    let s = "";
    for (let i = start; i < end; i++) {
      s += String.fromCharCode(raw[i]);
    }
    return s;
  }
  function readUnsignedInt2(bytes) {
    let val = 0;
    for (let i = bytes.length - 1; i >= 0; i--) {
      val = val * 256 + bytes[i];
    }
    return val;
  }
  function readSignedInt2(bytes) {
    const unsigned = readUnsignedInt2(bytes);
    const bits = bytes.length * 8;
    const max = Math.pow(2, bits);
    const signBit = max / 2;
    if (unsigned >= signBit) {
      return unsigned - max;
    }
    return unsigned;
  }

  // anchorwatch-bridge.ts
  function fromBase64(value) {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }
  function subfields(buffer, tag) {
    const field = parse2(buffer).records.flatMap((record) => record.fields).find((item) => item.tag === tag);
    return Object.fromEntries((field?.subfields ?? []).map((part) => [part.label, part.value]));
  }
  function metadata(buffer) {
    const dsid = subfields(buffer, "DSID");
    const dspm = subfields(buffer, "DSPM");
    return {
      name: dsid.DSNM ?? "",
      edition: dsid.EDTN ?? "",
      update: dsid.UPDN ?? "",
      updateDate: dsid.UADT ?? "",
      issueDate: dsid.ISDT ?? "",
      exchangeStandard: dsid.STED ?? "",
      scale: dspm.CSCL ?? 0,
      depthUnitCode: dspm.DUNI ?? 0,
      heightUnitCode: dspm.HUNI ?? 0,
      soundingDatumCode: dspm.SDAT ?? 0,
      verticalDatumCode: dspm.VDAT ?? 0,
      horizontalDatumCode: dspm.HDAT ?? 0,
      // Update records commonly omit DSPM entirely because these dataset
      // parameters belong to the base cell. Keep field-presence information
      // so an update's default zero values do not erase the base metadata.
      dspmFields: Object.keys(dspm)
    };
  }
  function mergeUpdateMetadata(previous, next) {
    const present = new Set(next.dspmFields ?? []);
    return {
      ...previous,
      ...next,
      scale: present.has("CSCL") ? next.scale : previous.scale,
      depthUnitCode: present.has("DUNI") ? next.depthUnitCode : previous.depthUnitCode,
      heightUnitCode: present.has("HUNI") ? next.heightUnitCode : previous.heightUnitCode,
      soundingDatumCode: present.has("SDAT") ? next.soundingDatumCode : previous.soundingDatumCode,
      verticalDatumCode: present.has("VDAT") ? next.verticalDatumCode : previous.verticalDatumCode,
      horizontalDatumCode: present.has("HDAT") ? next.horizontalDatumCode : previous.horizontalDatumCode
    };
  }
  // Keep update metadata merging isolated so it can be regression-tested directly.
  globalThis.anchorWatchMergeUpdateMetadata = mergeUpdateMetadata;
  globalThis.anchorWatchDecode = (base64, updateBase64sJSON) => {
    try {
      const base = fromBase64(base64);
      const dataset = parseS57(base);
      let latest = metadata(base);
      if (Number(latest.update) !== 0) throw new Error("Base cell does not begin at update zero.");
      const updates = JSON.parse(updateBase64sJSON);
      for (const [index, encoded] of updates.entries()) {
        const bytes = fromBase64(encoded);
        const next = metadata(bytes);
        const baseName = String(latest.name).replace(/\.\d{3}$/i, "").toUpperCase();
        const nextName = String(next.name).replace(/\.\d{3}$/i, "").toUpperCase();
        if (baseName !== nextName) throw new Error("Update cell ID does not match the base cell.");
        if (Number(next.update) !== index + 1) throw new Error("Update number in chart metadata does not match the file sequence.");
        applyUpdate(dataset, bytes);
        latest = mergeUpdateMetadata(latest, next);
      }
      const geo = toGeoJSON(dataset);
      const features = geo.features.map((feature, index) => {
        const source = dataset.features[index];
        const soundingDepths = Number(feature.properties.OBJL) === 129 ? source.spatialRefs.flatMap((ref) => dataset.spatialRecords.get(spatialKey(ref.rcnm, ref.rcid))?.coordinates3D.map((c) => c.depth) ?? []) : [];
        return {
          geometry: feature.geometry,
          soundingDepths,
          attributes: Object.fromEntries(Object.entries(feature.properties).map(([key, value]) => [key, String(value ?? "")]))
        };
      });
      return JSON.stringify({ ok: true, metadata: latest, features });
    } catch (error) {
      return JSON.stringify({ ok: false, error: String(error instanceof Error ? error.message : error) });
    }
  };
})();
