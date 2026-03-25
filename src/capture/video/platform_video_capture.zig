const Util = @import("../../util.zig");

pub const PlatformVideoCapture = if (Util.is_linux())
    @import("./linux/linux_pipewire_dma_capture.zig").LinuxPipewireDmaCapture
else
    @import("./windows/windows_video_capture.zig").WindowsVideoCapture;
