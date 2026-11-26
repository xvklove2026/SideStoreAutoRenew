// Run with icli probe from the project root. No screen or external files are read.
(function () {
    var env = ObjC.use('NSProcessInfo').processInfo().environment();
    var root = env.objectForKey_('APELIN_PROJECT_ROOT');
    if (!root) throw new Error('APELIN_PROJECT_ROOT is required');
    function crc(a) {
        var c = 0xffffffff;
        for (var i = 0; i < a.length; i++) {
            c ^= a[i];
            for (var j = 0; j < 8; j++) c = (c >>> 1) ^ ((c & 1) ? 0xedb88320 : 0);
        }
        return (c ^ 0xffffffff) >>> 0;
    }
    function u32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }
    function chunk(type, data) {
        var body = type.split('').map(function (c) { return c.charCodeAt(0); }).concat(data);
        return u32(data.length).concat(body, u32(crc(body)));
    }
    function base64(a) {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', out = '';
        for (var i = 0; i < a.length; i += 3) {
            var n = (a[i] << 16) | ((a[i + 1] || 0) << 8) | (a[i + 2] || 0);
            out += chars[(n >>> 18) & 63] + chars[(n >>> 12) & 63] +
                (i + 1 < a.length ? chars[(n >>> 6) & 63] : '=') + (i + 2 < a.length ? chars[n & 63] : '=');
        }
        return out;
    }
    var results = [];
    [29, 58, 87].forEach(function (size, scale) {
        var raw = [];
        for (var y = 0; y < size; y++) {
            raw.push(0);
            for (var x = 0; x < size; x++) {
                var px = (x + 0.5) / size, py = (y + 0.5) / size;
                var qx = Math.max(0.19 - px, 0, px - 0.81), qy = Math.max(0.19 - py, 0, py - 0.81);
                var alpha = qx * qx + qy * qy <= 0.18 * 0.18 ? 255 : 0;
                var dx = px - 0.5, dy = py - 0.5, radius = Math.sqrt(dx * dx + dy * dy);
                var angle = Math.atan2(dy, dx);
                var ring = radius > 0.235 && radius < 0.32 && !(angle > -0.9 && angle < -0.15);
                var arrow = px > 0.64 && px < 0.84 && py > 0.24 && py < 0.45 && py > 0.24 + (0.84 - px) * 0.7;
                var check = Math.abs(py - (px < 0.49 ? px + 0.10 : 1.08 - px)) < 0.035 && px > 0.385 && px < 0.625;
                var white = ring || arrow || check;
                raw.push(white ? 255 : 64 + Math.round(30 * py), white ? 255 : 67, white ? 255 : 215 + Math.round(28 * (1 - py)), alpha);
            }
        }
        var len = raw.length, z = [0x78, 0x01, 1, len & 255, len >>> 8, (~len) & 255, ((~len) >>> 8) & 255];
        var a = 1, b = 0;
        raw.forEach(function (v) { a = (a + v) % 65521; b = (b + a) % 65521; });
        z = z.concat(raw, u32(((b << 16) | a) >>> 0));
        var png = [137, 80, 78, 71, 13, 10, 26, 10].concat(
            chunk('IHDR', u32(size).concat(u32(size), [8, 6, 0, 0, 0])), chunk('IDAT', z), chunk('IEND', []));
        var name = 'icon' + (scale ? '@' + (scale + 1) + 'x' : '') + '.png';
        var data = ObjC.use('NSData').alloc().initWithBase64EncodedString_options_(base64(png), 0);
        if (!data.writeToFile_atomically_(root + '/Preferences/' + name, true)) throw new Error('Write failed: ' + name);
        results.push({file: name, pixels: size, bytes: png.length});
    });
    return results;
})();
