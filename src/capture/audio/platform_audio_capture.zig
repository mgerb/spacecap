const Util = @import("../../util.zig");

pub const PlatformAudioCapture = if (Util.isLinux())
    @import("./linux/linux_audio_capture.zig").LinuxAudioCapture
else
    @import("./windows/windows_audio_capture.zig").WindowsAudioCapture;
