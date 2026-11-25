import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("wallpaperSpan.depCheck", ["sh", "-c", "command -v magick >/dev/null 2>&1 || (command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1)"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": "ImageMagick is required",
                "details": "Wallpaper Span uses ImageMagick ('magick' or 'convert'/'identify') to inspect dimensions and split wide wallpapers.\n\nInstall it on Arch/CachyOS with:\n  sudo pacman -S imagemagick\n\nThen re-enable the plugin."
            });
        });
    }
}
