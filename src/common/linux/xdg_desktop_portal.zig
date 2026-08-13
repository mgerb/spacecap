//! dbus constants

pub const DBUS_DESTINATION: [:0]const u8 = "org.freedesktop.portal.Desktop";
pub const DBUS_OBJECT_PATH: [:0]const u8 = "/org/freedesktop/portal/desktop";

// Interface
pub const FILE_CHOOSER_INTERFACE: [:0]const u8 = "org.freedesktop.portal.FileChooser";
pub const GLOBAL_SHORTCUTS_INTERFACE: [:0]const u8 = "org.freedesktop.portal.GlobalShortcuts";
pub const REGISTRY_INTERFACE: [:0]const u8 = "org.freedesktop.host.portal.Registry";
pub const REQUEST_INTERFACE: [:0]const u8 = "org.freedesktop.portal.Request";
pub const SESSION_INTERFACE: [:0]const u8 = "org.freedesktop.portal.Session";

// Method
pub const BIND_SHORTCUTS_METHOD: [:0]const u8 = "BindShortcuts";
pub const CLOSE_METHOD: [:0]const u8 = "Close";
pub const CONFIGURE_SHORTCUTS_METHOD: [:0]const u8 = "ConfigureShortcuts";
pub const CREATE_SESSION_METHOD: [:0]const u8 = "CreateSession";
pub const OPEN_FILE_METHOD: [:0]const u8 = "OpenFile";
pub const REGISTER_METHOD: [:0]const u8 = "Register";

// Signal
pub const ACTIVATED_SIGNAL: [:0]const u8 = "Activated";
pub const RESPONSE_SIGNAL: [:0]const u8 = "Response";
