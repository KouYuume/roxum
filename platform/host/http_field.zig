//! Borrowed HTTP field bytes shared by transport input and request conversion.
//! This type carries no validation or ownership guarantee by itself.
pub const Header = struct { name: []const u8, value: []const u8 };
