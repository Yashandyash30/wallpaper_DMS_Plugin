.pragma library

function resolveMonitors(screens, isNiri, niriOutputs, isHyprland, hyprMonitors, monitorDiagonals) {
    if (!screens || screens.length === 0)
        return [];

    var hyprMap = {};
    if (isHyprland && hyprMonitors) {
        for (var h = 0; h < hyprMonitors.length; h++) {
            var hm = hyprMonitors[h];
            if (hm && hm.name)
                hyprMap[hm.name] = hm;
        }
    }

    var diagOverrides = monitorDiagonals || {};
    var monitors = [];

    for (var i = 0; i < screens.length; i++) {
        var s = screens[i];
        if (!s || !s.name)
            continue;

        var x = typeof s.x === "number" ? s.x : 0;
        var y = typeof s.y === "number" ? s.y : 0;
        var w = typeof s.width === "number" && s.width > 0 ? s.width : 1920;
        var h = typeof s.height === "number" && s.height > 0 ? s.height : 1080;
        var diagMm = 0;

        if (isNiri && niriOutputs && niriOutputs[s.name]) {
            var no = niriOutputs[s.name];
            if (no.logical) {
                if (typeof no.logical.x === "number") x = no.logical.x;
                if (typeof no.logical.y === "number") y = no.logical.y;
                if (typeof no.logical.width === "number" && no.logical.width > 0) w = no.logical.width;
                if (typeof no.logical.height === "number" && no.logical.height > 0) h = no.logical.height;
            }
            if (no.physical_size && no.physical_size.length >= 2 && no.physical_size[0] > 0 && no.physical_size[1] > 0) {
                diagMm = Math.sqrt(no.physical_size[0] * no.physical_size[0] + no.physical_size[1] * no.physical_size[1]);
            }
        } else if (isHyprland && hyprMap[s.name]) {
            var hl = hyprMap[s.name];
            if (typeof hl.x === "number") x = hl.x;
            if (typeof hl.y === "number") y = hl.y;
            var scale = (typeof hl.scale === "number" && hl.scale > 0) ? hl.scale : 1;
            if (typeof hl.width === "number" && hl.width > 0) w = Math.round(hl.width / scale);
            if (typeof hl.height === "number" && hl.height > 0) h = Math.round(hl.height / scale);
        }

        if (diagMm <= 0 && typeof s.physicalPixelDensity === "number" && s.physicalPixelDensity > 0) {
            diagMm = Math.sqrt(w * w + h * h) / s.physicalPixelDensity;
        }
        if (diagMm <= 0) {
            diagMm = 24.0 * 25.4;
        }

        var overrideInches = Number(diagOverrides[s.name]);
        if (!isNaN(overrideInches) && overrideInches >= 5 && overrideInches <= 120) {
            diagMm = overrideInches * 25.4;
        }

        // Derive physical width/height from diagonal + exact pixel aspect ratio (Spanright method)
        // so rounded EDID dimensions never skew aspect ratios.
        var diagPx = Math.sqrt(w * w + h * h);
        var pxPerMm = diagPx / diagMm;
        var physW = w / pxPerMm;
        var physH = h / pxPerMm;

        monitors.push({
            name: s.name,
            model: s.model || "",
            x: x,
            y: y,
            width: w,
            height: h,
            diagMm: diagMm,
            diagInches: Math.round((diagMm / 25.4) * 10) / 10,
            pxPerMm: pxPerMm,
            physW: physW,
            physH: physH
        });
    }

    monitors.sort(function(a, b) {
        return (a.x - b.x) || (a.y - b.y) || a.name.localeCompare(b.name);
    });

    if (monitors.length > 1) {
        var allOrigin = true;
        for (var j = 0; j < monitors.length; j++) {
            if (monitors[j].x !== 0 || monitors[j].y !== 0) {
                allOrigin = false;
                break;
            }
        }
        if (allOrigin) {
            var curX = 0;
            for (var k = 0; k < monitors.length; k++) {
                monitors[k].x = curX;
                curX += monitors[k].width;
            }
        }
    }

    return monitors;
}

function isWideImage(imgW, imgH, threshold) {
    if (!imgW || !imgH || imgW <= 0 || imgH <= 0)
        return false;
    var limit = (typeof threshold === "number" && threshold > 0) ? threshold : 2.2;
    return (imgW / imgH) >= limit;
}

function buildPhysicalLayout(monitors, monitorOffsets, bezelGapMm) {
    if (!monitors || monitors.length === 0)
        return [];

    var offsets = monitorOffsets || {};
    var gapMm = (typeof bezelGapMm === "number" && bezelGapMm >= 0) ? bezelGapMm : 0;

    var minLogX = monitors[0].x;
    var minLogY = monitors[0].y;
    for (var i = 1; i < monitors.length; i++) {
        if (monitors[i].x < minLogX) minLogX = monitors[i].x;
        if (monitors[i].y < minLogY) minLogY = monitors[i].y;
    }

    // Place monitors in physical space (mm), advancing left-to-right with bezelGapMm between columns
    // and vertically aligning baselines + per-monitor vertical offset (mm).
    var placed = [];
    var curX = 0;
    for (var j = 0; j < monitors.length; j++) {
        var m = monitors[j];
        var pxPerMm = (m.pxPerMm && m.pxPerMm > 0) ? m.pxPerMm : (Math.sqrt(m.width * m.width + m.height * m.height) / (24.0 * 25.4));
        var physW = (m.physW && m.physW > 0) ? m.physW : (m.width / pxPerMm);
        var physH = (m.physH && m.physH > 0) ? m.physH : (m.height / pxPerMm);
        var offsetMm = (Number(offsets[m.name]) || 0) / pxPerMm;

        var physX, physY;
        if (j === 0) {
            physX = 0;
            physY = offsetMm;
            curX = physW;
        } else {
            var prev = monitors[j - 1];
            var sameRow = Math.abs(m.y - prev.y) < Math.max(m.height, prev.height) * 0.5 && m.x >= prev.x + prev.width * 0.5;
            if (sameRow) {
                physX = curX + gapMm;
                var prevPxPerMm = placed[j - 1].pxPerMm;
                var logicalDyMm = (m.y - prev.y) / prevPxPerMm;
                physY = (placed[j - 1].baseY + logicalDyMm) + offsetMm;
                curX = physX + physW;
            } else {
                physX = (m.x - minLogX) / pxPerMm;
                physY = ((m.y - minLogY) / pxPerMm) + offsetMm;
            }
        }

        placed.push({
            name: m.name,
            width: m.width,
            height: m.height,
            pxPerMm: pxPerMm,
            physW: physW,
            physH: physH,
            physX: physX,
            physY: physY,
            baseY: physY - offsetMm
        });
    }

    return placed;
}

function computeSpanCrops(imgW, imgH, monitors, fitMode, monitorOffsets, options) {
    if (!monitors || monitors.length === 0 || imgW <= 0 || imgH <= 0)
        return [];

    var mode = fitMode || "physical";
    var offsets = monitorOffsets || {};
    var opts = options || {};
    var bezelGapMm = (typeof opts.bezelGapMm === "number" && opts.bezelGapMm >= 0) ? opts.bezelGapMm : 0;

    if (mode === "physical") {
        var placed = buildPhysicalLayout(monitors, offsets, bezelGapMm);
        var pMinX = placed[0].physX;
        var pMinY = placed[0].physY;
        var pMaxX = placed[0].physX + placed[0].physW;
        var pMaxY = placed[0].physY + placed[0].physH;

        for (var p = 1; p < placed.length; p++) {
            if (placed[p].physX < pMinX) pMinX = placed[p].physX;
            if (placed[p].physY < pMinY) pMinY = placed[p].physY;
            if (placed[p].physX + placed[p].physW > pMaxX) pMaxX = placed[p].physX + placed[p].physW;
            if (placed[p].physY + placed[p].physH > pMaxY) pMaxY = placed[p].physY + placed[p].physH;
        }

        var totalPhysW = Math.max(1, pMaxX - pMinX);
        var totalPhysH = Math.max(1, pMaxY - pMinY);
        var physAspect = totalPhysW / totalPhysH;
        var imgAspectPhys = imgW / imgH;

        var imgPhysW, imgPhysH, imgLeft, imgTop;
        if (imgAspectPhys >= physAspect) {
            imgPhysH = totalPhysH;
            imgPhysW = totalPhysH * imgAspectPhys;
            imgLeft = pMinX - (imgPhysW - totalPhysW) / 2.0;
            imgTop = pMinY;
        } else {
            imgPhysW = totalPhysW;
            imgPhysH = totalPhysW / imgAspectPhys;
            imgLeft = pMinX;
            imgTop = pMinY - (imgPhysH - totalPhysH) / 2.0;
        }

        var imgPxPerMm = imgW / imgPhysW;
        var physCrops = [];
        for (var q = 0; q < placed.length; q++) {
            var pm = placed[q];
            var sx = (pm.physX - imgLeft) * imgPxPerMm;
            var sy = (pm.physY - imgTop) * imgPxPerMm;
            var sw = pm.physW * imgPxPerMm;
            var sh = pm.physH * imgPxPerMm;

            var pcx = Math.max(0, Math.min(imgW - 1, Math.round(sx)));
            var pcy = Math.max(0, Math.min(imgH - 1, Math.round(sy)));
            var pcw = Math.max(1, Math.min(imgW - pcx, Math.round(sx + sw) - pcx));
            var pch = Math.max(1, Math.min(imgH - pcy, Math.round(sy + sh) - pcy));

            physCrops.push({
                name: pm.name,
                x: pcx,
                y: pcy,
                w: pcw,
                h: pch
            });
        }
        return physCrops;
    }

    var boxes = [];
    var seamCenterX = imgW / 2.0;
    var refY = 0;

    if (mode === "equal") {
        var count = monitors.length;
        var baseW = imgW / count;
        for (var i = 0; i < count; i++) {
            var monEq = monitors[i];
            var offEq = Number(offsets[monEq.name]) || 0;
            var monH = (monEq.height && monEq.height > 0) ? monEq.height : 1080;
            boxes.push({
                name: monEq.name,
                rx: i * baseW,
                ry: 0,
                rw: baseW,
                rh: imgH,
                shiftImg: offEq * (imgH / monH)
            });
        }
    } else {
        var minX = monitors[0].x;
        var minY = monitors[0].y;
        var maxX = monitors[0].x + monitors[0].width;
        var maxY = monitors[0].y + monitors[0].height;

        for (var m = 1; m < monitors.length; m++) {
            if (monitors[m].x < minX) minX = monitors[m].x;
            if (monitors[m].y < minY) minY = monitors[m].y;
            if (monitors[m].x + monitors[m].width > maxX) maxX = monitors[m].x + monitors[m].width;
            if (monitors[m].y + monitors[m].height > maxY) maxY = monitors[m].y + monitors[m].height;
        }

        var totalW = Math.max(1, maxX - minX);
        var totalH = Math.max(1, maxY - minY);
        var layoutAspect = totalW / totalH;
        var imgAspect = imgW / imgH;

        var regionW, regionH, regionX, regionY;
        if (imgAspect >= layoutAspect) {
            regionH = imgH;
            regionW = imgH * layoutAspect;
            regionX = (imgW - regionW) / 2.0;
            regionY = 0;
        } else {
            regionW = imgW;
            regionH = imgW / layoutAspect;
            regionX = 0;
            regionY = (imgH - regionH) / 2.0;
        }

        seamCenterX = regionX + regionW / 2.0;
        refY = regionY;
        var scaleY = regionH / totalH;

        for (var j = 0; j < monitors.length; j++) {
            var mon = monitors[j];
            var off = Number(offsets[mon.name]) || 0;
            boxes.push({
                name: mon.name,
                rx: regionX + ((mon.x - minX) / totalW) * regionW,
                ry: regionY + ((mon.y - minY) / totalH) * regionH,
                rw: (mon.width / totalW) * regionW,
                rh: (mon.height / totalH) * regionH,
                shiftImg: off * scaleY
            });
        }
    }

    var minRel = Infinity;
    var maxRel = -Infinity;
    for (var b = 0; b < boxes.length; b++) {
        var relTop = (boxes[b].ry - refY) + boxes[b].shiftImg;
        var relBot = relTop + boxes[b].rh;
        boxes[b].relTop = relTop;
        if (relTop < minRel) minRel = relTop;
        if (relBot > maxRel) maxRel = relBot;
    }

    var spanRel = Math.max(1, maxRel - minRel);
    var zoom = spanRel > imgH ? (imgH / spanRel) : 1.0;
    var baseY = spanRel > imgH
        ? (-zoom * minRel)
        : Math.max(-minRel, Math.min(imgH - maxRel, refY));

    var crops = [];
    for (var k = 0; k < boxes.length; k++) {
        var box = boxes[k];
        var fx = seamCenterX + zoom * (box.rx - seamCenterX);
        var fw = zoom * box.rw;
        var fy = baseY + zoom * box.relTop;
        var fh = zoom * box.rh;

        var cx = Math.max(0, Math.min(imgW - 1, Math.round(fx)));
        var cy = Math.max(0, Math.min(imgH - 1, Math.round(fy)));
        var cw = Math.max(1, Math.min(imgW - cx, Math.round(fx + fw) - cx));
        var ch = Math.max(1, Math.min(imgH - cy, Math.round(fy + fh) - cy));

        crops.push({
            name: box.name,
            x: cx,
            y: cy,
            w: cw,
            h: ch
        });
    }

    return crops;
}

function layoutSignature(monitors, fitMode, monitorOffsets, options) {
    if (!monitors || monitors.length === 0)
        return fitMode || "physical";
    var mode = fitMode || "physical";
    var offsets = monitorOffsets || {};
    var opts = options || {};
    var gapMm = (typeof opts.bezelGapMm === "number" && opts.bezelGapMm >= 0) ? opts.bezelGapMm : 0;
    var parts = [mode, "gap=" + gapMm];
    for (var i = 0; i < monitors.length; i++) {
        var m = monitors[i];
        var off = Number(offsets[m.name]) || 0;
        var diag = Math.round(m.diagMm || 0);
        parts.push(m.name + ":" + m.x + "," + m.y + "," + m.width + "x" + m.height + ",d" + diag + "@" + off);
    }
    return parts.join("|");
}

function formatAspectLabel(w, h) {
    if (!w || !h || w <= 0 || h <= 0)
        return "";
    var r = w / h;
    var known = [
        { ratio: 32 / 9, label: "32:9" },
        { ratio: 32 / 10, label: "32:10" },
        { ratio: 21 / 9, label: "21:9" },
        { ratio: 16 / 9, label: "16:9" },
        { ratio: 16 / 10, label: "16:10" },
        { ratio: 3 / 2, label: "3:2" },
        { ratio: 4 / 3, label: "4:3" },
        { ratio: 1, label: "1:1" },
        { ratio: 9 / 16, label: "9:16" }
    ];
    for (var i = 0; i < known.length; i++) {
        if (Math.abs(r - known[i].ratio) <= 0.08)
            return known[i].label;
    }
    return r >= 1 ? r.toFixed(1) + ":1" : "1:" + (1 / r).toFixed(1);
}

var VIDEO_EXT_RE = /\.(mp4|mkv|webm|mov|m4v|avi|flv|wmv)$/i;

function isVideoPath(path) {
    return typeof path === "string" && VIDEO_EXT_RE.test(path);
}

function formatMpvCrop(crop) {
    if (!crop || crop.w <= 0 || crop.h <= 0)
        return "";
    return crop.w + "x" + crop.h + "+" + crop.x + "+" + crop.y;
}

function buildMpvArgs(monitor, videoPath, settings, cropGeom) {
    var s = settings || {};
    var opts = [
        "loop",
        "--hwdec-codecs=all",
        "--vo=gpu",
        "--gpu-api=auto",
        "--gpu-context=auto",
        "--profile=fast",
        "--video-sync=display-resample",
        "--interpolation=no",
        "--scale=bilinear",
        "--cscale=bilinear",
        "--dscale=bilinear",
        "--correct-downscaling=no",
        "--linear-downscaling=no",
        "--sigmoid-upscaling=no",
        "--vd-lavc-threads=1",
        "--cache=no",
        "--demuxer-max-bytes=10M",
        "--demuxer-readahead-secs=1",
        "--vd-lavc-dr=yes",
        "--opengl-pbo",
        "--swapchain-depth=1",
        "--no-audio-display",
        "--no-osc",
        "--no-osd-bar",
        "--no-input-default-bindings",
        "--no-input-cursor",
        "--cursor-autohide=no",
        "--no-keepaspect-window"
    ];

    var hwdec = s.hwdec || "auto";
    if (hwdec !== "no")
        opts.push("--hwdec=" + hwdec);

    var panscan = (typeof s.panscan === "number" && !isNaN(s.panscan)) ? s.panscan : 1.0;
    opts.push("--panscan=" + panscan);

    var volume = (typeof s.volume === "number" && !isNaN(s.volume)) ? Math.max(0, Math.min(100, Math.round(s.volume))) : 0;
    opts.push("--volume=" + volume);

    if (cropGeom && typeof cropGeom === "string" && cropGeom.length > 0)
        opts.push("--video-crop=" + cropGeom);

    return ["mpvpaper", "-l", "background", "-o", opts.join(" "), monitor, videoPath];
}

function niriOutputHasColumn(monitorName, workspaces, windows) {
    if (!monitorName || !workspaces || workspaces.length === 0)
        return false;

    var activeWs = null;
    for (var i = 0; i < workspaces.length; i++) {
        var ws = workspaces[i];
        if (ws && ws.output === monitorName && ws.is_active) {
            activeWs = ws;
            break;
        }
    }
    if (!activeWs)
        return false;

    var winList = windows || [];
    for (var j = 0; j < winList.length; j++) {
        var win = winList[j];
        if (!win || win.workspace_id !== activeWs.id)
            continue;
        if (win.is_floating === true)
            continue;
        return true;
    }
    return false;
}
