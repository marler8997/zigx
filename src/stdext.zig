pub const enums = struct {
    /// Returns true if `enum_value` has a name. This function always returns true
    /// for exhaustive enums.  It will return false if the enum is non-exhaustive
    /// and the value does not have a corresponding name.
    pub fn hasName(enum_value: anytype) bool {
        const T = @TypeOf(enum_value);
        const enum_info = switch (@typeInfo(T)) {
            .Enum => |enum_info| enum_info,
            else => @compileError("hasName requires an enum value but got " ++ @typeName(T)),
        };
        if (enum_info.is_exhaustive)
            return true;

        @setEvalBranchQuota(3 * enum_info.fields.len);
        inline for (enum_info.fields) |enum_field| {
            if (@intFromEnum(enum_value) == enum_field.value)
                return true;
        }

        return false;
    }
};
