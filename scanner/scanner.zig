pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = std.process.args();
    _ = args.next(); // skip program name

    var xml_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var out_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = args.next() orelse errExit("expected output path after -o", .{});
        } else {
            try xml_paths.append(arena, arg);
        }
    }
    if (xml_paths.items.len == 0) errExit("expected at least one XML input file", .{});

    var protocols: std.ArrayListUnmanaged(Protocol) = .empty;
    for (xml_paths.items) |xml_path| {
        const _1_GB = 1 * 1024 * 1024 * 1024;
        const data = std.fs.cwd().readFileAlloc(arena, xml_path, _1_GB) catch |err|
            errExit("failed to read '{s}': {s}", .{ xml_path, @errorName(err) });
        var ctx = Context{ .filename = xml_path, .data = data, .parser = .{ .data = data } };
        try protocols.append(arena, parseXcb(&ctx, arena));
    }

    const out_file = if (out_path) |p|
        std.fs.cwd().createFile(p, .{}) catch |e|
            errExit("failed to create output file '{s}': {s}", .{ p, @errorName(e) })
    else
        std.fs.File.stdout();

    var write_buf: [8192]u8 = undefined;
    var file_writer = out_file.writer(&write_buf);
    const writer = &file_writer.interface;

    generate(writer, protocols.items) catch |err| switch (err) {
        error.WriteFailed => return file_writer.err.?,
    };
}

// ============================================================================
// Context for error reporting
// ============================================================================

const Context = struct {
    filename: []const u8,
    data: []const u8,
    parser: xml.Parser,

    fn fail(ctx: *const Context, comptime fmt: []const u8, args: anytype) noreturn {
        const loc = ctx.computeLocation();
        std.debug.print("{s}:{d}:{d}: error: ", .{ ctx.filename, loc.line, loc.col });
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        std.process.exit(1);
    }

    const Location = struct { line: u32, col: u32 };

    fn computeLocation(ctx: *const Context) Location {
        var line: u32 = 1;
        var col: u32 = 1;
        for (ctx.data[0..ctx.parser.pos]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .col = col };
    }
};

// ============================================================================
// IR types
// ============================================================================

const Protocol = struct {
    header: []const u8,
    extension_xname: ?[]const u8,
    extension_name: ?[]const u8,
    major_version: ?u32,
    minor_version: ?u32,
    imports: []const []const u8,
    xidtypes: []const []const u8,
    xidunions: []const XidUnion,
    typedefs: []const Typedef,
    enums: []const Enum,
    structs: []const Struct,
    unions: []const Union,
    requests: []const Request,
    events: []const Event,
    eventcopies: []const EventCopy,
    eventstructs: []const EventStruct,
    errors: []const XError,
    errorcopies: []const ErrorCopy,
};

const XidUnion = struct {
    name: []const u8,
    types: []const []const u8,
};

const Typedef = struct {
    oldname: []const u8,
    newname: []const u8,
};

const Enum = struct {
    name: []const u8,
    items: []const EnumItem,
};

const EnumItem = struct {
    name: []const u8,
    value: Value,
    const Value = union(enum) { value: i64, bit: u6 };
};

const Struct = struct {
    name: []const u8,
    members: []const StructMember,
};

const Union = struct {
    name: []const u8,
    members: []const StructMember,
};

const Request = struct {
    name: []const u8,
    opcode: u16,
    combine_adjacent: bool,
    members: []const StructMember,
    reply: ?[]const StructMember,
};

const Event = struct {
    name: []const u8,
    number: u16,
    no_sequence_number: bool,
    is_xge: bool,
    members: []const StructMember,
};

const EventCopy = struct {
    name: []const u8,
    number: u16,
    ref: []const u8,
};

const EventStruct = struct {
    name: []const u8,
    alloweds: []const EventStructAllowed,
};

const EventStructAllowed = struct {
    extension: []const u8,
    is_xge: bool,
    opcode_min: u16,
    opcode_max: u16,
};

const XError = struct {
    name: []const u8,
    number: i32,
    members: []const StructMember,
};

const ErrorCopy = struct {
    name: []const u8,
    number: u16,
    ref: []const u8,
};

const StructMember = union(enum) {
    field: Field,
    pad: PadInfo,
    list: List,
    exprfield: ExprField,
    @"switch": Switch,
    fd: []const u8, // fd name
    required_start_align: AlignInfo,
    value_param: ValueParam,
};

const Field = struct {
    name: []const u8,
    type: []const u8,
    enum_ref: ?[]const u8,
    mask_ref: ?[]const u8,
    altenum_ref: ?[]const u8,
    altmask_ref: ?[]const u8,
};

const PadInfo = union(enum) {
    bytes: u32,
    @"align": u32,
};

const List = struct {
    name: []const u8,
    type: []const u8,
    enum_ref: ?[]const u8,
    mask_ref: ?[]const u8,
    length_expr: ?*const Expr,
};

const ExprField = struct {
    name: []const u8,
    type: []const u8,
    expr: *const Expr,
};

const Switch = struct {
    name: []const u8,
    expr: *const Expr,
    cases: []const Case,
    is_bitcase: bool,
};

const Case = struct {
    name: ?[]const u8,
    exprs: []const *const Expr,
    members: []const StructMember,
};

const ValueParam = struct {
    value_mask_type: []const u8,
    value_mask_name: []const u8,
    value_list_name: []const u8,
};

const AlignInfo = struct {
    @"align": u32,
    offset: u32,
};

const Expr = union(enum) {
    value: i64,
    fieldref: []const u8,
    paramref: ParamRef,
    enumref: EnumRef,
    op: Op,
    unop: UnOp,
    popcount: *const Expr,
    sumof: SumOf,
    listelement_ref: void,
    list_length: void,

    const ParamRef = struct {
        type: []const u8,
        name: []const u8,
    };
    const EnumRef = struct {
        ref: []const u8,
        name: []const u8,
    };
    const Op = struct {
        operator: []const u8,
        lhs: *const Expr,
        rhs: *const Expr,
    };
    const UnOp = struct {
        operator: []const u8,
        operand: *const Expr,
    };
    const SumOf = struct {
        ref: []const u8,
        operand: ?*const Expr,
    };
};

// ============================================================================
// Parsing
// ============================================================================

fn parseXcb(ctx: *Context, arena: std.mem.Allocator) Protocol {
    while (ctx.parser.nextTag()) |tag| {
        if (!tag.is_closing and std.mem.eql(u8, tag.name, "xcb")) {
            return parseXcbBody(ctx, arena, tag);
        }
    }
    ctx.fail("no <xcb> tag found", .{});
}

fn parseXcbBody(ctx: *Context, arena: std.mem.Allocator, xcb_tag: xml.Tag) Protocol {
    var imports: std.ArrayListUnmanaged([]const u8) = .empty;
    var xidtypes: std.ArrayListUnmanaged([]const u8) = .empty;
    var xidunions: std.ArrayListUnmanaged(XidUnion) = .empty;
    var typedefs: std.ArrayListUnmanaged(Typedef) = .empty;
    var enums: std.ArrayListUnmanaged(Enum) = .empty;
    var structs: std.ArrayListUnmanaged(Struct) = .empty;
    var unions: std.ArrayListUnmanaged(Union) = .empty;
    var requests: std.ArrayListUnmanaged(Request) = .empty;
    var events: std.ArrayListUnmanaged(Event) = .empty;
    var eventcopies: std.ArrayListUnmanaged(EventCopy) = .empty;
    var eventstructs: std.ArrayListUnmanaged(EventStruct) = .empty;
    var errors: std.ArrayListUnmanaged(XError) = .empty;
    var errorcopies: std.ArrayListUnmanaged(ErrorCopy) = .empty;

    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing) {
            if (std.mem.eql(u8, tag.name, "xcb")) break;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "import")) {
            imports.append(arena, ctx.parser.getTextUntilClose("import")) catch oom();
        } else if (std.mem.eql(u8, tag.name, "xidtype")) {
            xidtypes.append(arena, reqAttr(ctx, tag, "name")) catch oom();
        } else if (std.mem.eql(u8, tag.name, "xidunion")) {
            xidunions.append(arena, parseXidUnion(ctx, arena, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "typedef")) {
            typedefs.append(arena, .{
                .oldname = reqAttr(ctx, tag, "oldname"),
                .newname = reqAttr(ctx, tag, "newname"),
            }) catch oom();
        } else if (std.mem.eql(u8, tag.name, "enum")) {
            enums.append(arena, parseEnum(ctx, arena, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "struct")) {
            structs.append(arena, .{
                .name = reqAttr(ctx, tag, "name"),
                .members = parseStructMembers(ctx, arena, "struct"),
            }) catch oom();
        } else if (std.mem.eql(u8, tag.name, "union")) {
            unions.append(arena, .{
                .name = reqAttr(ctx, tag, "name"),
                .members = parseStructMembers(ctx, arena, "union"),
            }) catch oom();
        } else if (std.mem.eql(u8, tag.name, "request")) {
            requests.append(arena, parseRequest(ctx, arena, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "event")) {
            events.append(arena, parseEvent(ctx, arena, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "eventcopy")) {
            eventcopies.append(arena, .{
                .name = reqAttr(ctx, tag, "name"),
                .number = parseU16(ctx, reqAttr(ctx, tag, "number")),
                .ref = reqAttr(ctx, tag, "ref"),
            }) catch oom();
        } else if (std.mem.eql(u8, tag.name, "eventstruct")) {
            eventstructs.append(arena, parseEventStruct(ctx, arena, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "error")) {
            errors.append(arena, parseError(ctx, arena, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "errorcopy")) {
            errorcopies.append(arena, .{
                .name = reqAttr(ctx, tag, "name"),
                .number = parseU16(ctx, reqAttr(ctx, tag, "number")),
                .ref = reqAttr(ctx, tag, "ref"),
            }) catch oom();
        } else {
            ctx.fail("unrecognized top-level xcb tag: '{s}'", .{tag.name});
        }
    }

    return .{
        .header = reqAttr(ctx, xcb_tag, "header"),
        .extension_xname = xcb_tag.getAttr("extension-xname"),
        .extension_name = xcb_tag.getAttr("extension-name"),
        .major_version = if (xcb_tag.getAttr("major-version")) |v| parseU32(ctx, v) else null,
        .minor_version = if (xcb_tag.getAttr("minor-version")) |v| parseU32(ctx, v) else null,
        .imports = (imports.toOwnedSlice(arena) catch oom()),
        .xidtypes = (xidtypes.toOwnedSlice(arena) catch oom()),
        .xidunions = (xidunions.toOwnedSlice(arena) catch oom()),
        .typedefs = (typedefs.toOwnedSlice(arena) catch oom()),
        .enums = (enums.toOwnedSlice(arena) catch oom()),
        .structs = (structs.toOwnedSlice(arena) catch oom()),
        .unions = (unions.toOwnedSlice(arena) catch oom()),
        .requests = (requests.toOwnedSlice(arena) catch oom()),
        .events = (events.toOwnedSlice(arena) catch oom()),
        .eventcopies = (eventcopies.toOwnedSlice(arena) catch oom()),
        .eventstructs = (eventstructs.toOwnedSlice(arena) catch oom()),
        .errors = (errors.toOwnedSlice(arena) catch oom()),
        .errorcopies = (errorcopies.toOwnedSlice(arena) catch oom()),
    };
}

fn parseXidUnion(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) XidUnion {
    var types: std.ArrayListUnmanaged([]const u8) = .empty;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "xidunion")) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "type")) {
            types.append(arena, ctx.parser.getTextUntilClose("type")) catch oom();
        } else {
            ctx.fail("unrecognized tag in xidunion: '{s}'", .{tag.name});
        }
    }
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .types = types.toOwnedSlice(arena) catch oom(),
    };
}

fn parseEnum(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) Enum {
    var items: std.ArrayListUnmanaged(EnumItem) = .empty;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "enum")) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "item")) {
            items.append(arena, parseEnumItem(ctx, tag)) catch oom();
        } else if (std.mem.eql(u8, tag.name, "doc")) {
            ctx.parser.skipToClose("doc");
        } else {
            ctx.fail("unrecognized tag in enum: '{s}'", .{tag.name});
        }
    }
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .items = items.toOwnedSlice(arena) catch oom(),
    };
}

fn parseEnumItem(ctx: *Context, open_tag: xml.Tag) EnumItem {
    if (open_tag.self_closing) {
        ctx.fail("enum item with no value", .{});
    }
    var value: ?EnumItem.Value = null;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "item")) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "value")) {
            const text = ctx.parser.getTextUntilClose("value");
            value = .{ .value = std.fmt.parseInt(i64, text, 0) catch
                ctx.fail("invalid enum value: '{s}'", .{text}) };
        } else if (std.mem.eql(u8, tag.name, "bit")) {
            const text = ctx.parser.getTextUntilClose("bit");
            value = .{ .bit = std.fmt.parseInt(u6, text, 10) catch
                ctx.fail("invalid bit value: '{s}'", .{text}) };
        } else {
            ctx.fail("unrecognized tag in enum item: '{s}'", .{tag.name});
        }
    }
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .value = value orelse ctx.fail("enum item missing value", .{}),
    };
}

fn parseStructMembers(ctx: *Context, arena: std.mem.Allocator, close_tag_name: []const u8) []const StructMember {
    var members: std.ArrayListUnmanaged(StructMember) = .empty;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, close_tag_name)) break;
        if (tag.is_closing) continue;
        if (parseMember(ctx, arena, tag)) |member| {
            members.append(arena, member) catch oom();
        }
    }
    return members.toOwnedSlice(arena) catch oom();
}

fn parseMember(ctx: *Context, arena: std.mem.Allocator, tag: xml.Tag) ?StructMember {
    if (std.mem.eql(u8, tag.name, "field")) {
        return .{ .field = .{
            .name = reqAttr(ctx, tag, "name"),
            .type = reqAttr(ctx, tag, "type"),
            .enum_ref = tag.getAttr("enum"),
            .mask_ref = tag.getAttr("mask"),
            .altenum_ref = tag.getAttr("altenum"),
            .altmask_ref = tag.getAttr("altmask"),
        } };
    } else if (std.mem.eql(u8, tag.name, "pad")) {
        if (tag.getAttr("bytes")) |b| {
            return .{ .pad = .{ .bytes = parseU32(ctx, b) } };
        } else if (tag.getAttr("align")) |a| {
            return .{ .pad = .{ .@"align" = parseU32(ctx, a) } };
        } else {
            ctx.fail("pad with neither bytes nor align", .{});
        }
    } else if (std.mem.eql(u8, tag.name, "list")) {
        return .{ .list = parseList(ctx, arena, tag) };
    } else if (std.mem.eql(u8, tag.name, "exprfield")) {
        if (tag.self_closing) ctx.fail("exprfield must have an expression", .{});
        const expr = parseExpr(ctx, arena, "exprfield");
        return .{ .exprfield = .{
            .name = reqAttr(ctx, tag, "name"),
            .type = reqAttr(ctx, tag, "type"),
            .expr = expr,
        } };
    } else if (std.mem.eql(u8, tag.name, "switch")) {
        return .{ .@"switch" = parseSwitch(ctx, arena, tag) };
    } else if (std.mem.eql(u8, tag.name, "fd")) {
        return .{ .fd = reqAttr(ctx, tag, "name") };
    } else if (std.mem.eql(u8, tag.name, "required_start_align")) {
        return .{ .required_start_align = .{
            .@"align" = parseU32(ctx, reqAttr(ctx, tag, "align")),
            .offset = if (tag.getAttr("offset")) |o| parseU32(ctx, o) else 0,
        } };
    } else if (std.mem.eql(u8, tag.name, "length")) {
        if (!tag.self_closing) ctx.parser.skipToClose("length");
        return null;
    } else if (std.mem.eql(u8, tag.name, "valueparam")) {
        return .{ .value_param = .{
            .value_mask_type = reqAttr(ctx, tag, "value-mask-type"),
            .value_mask_name = reqAttr(ctx, tag, "value-mask-name"),
            .value_list_name = reqAttr(ctx, tag, "value-list-name"),
        } };
    } else if (std.mem.eql(u8, tag.name, "doc")) {
        ctx.parser.skipToClose("doc");
        return null;
    } else if (std.mem.eql(u8, tag.name, "reply")) {
        ctx.fail("unexpected <reply> in struct members", .{});
    } else {
        ctx.fail("unrecognized struct member tag: '{s}'", .{tag.name});
    }
}

fn parseList(ctx: *Context, arena: std.mem.Allocator, tag: xml.Tag) List {
    var length_expr: ?*const Expr = null;
    if (!tag.self_closing) {
        while (ctx.parser.nextTag()) |inner| {
            if (inner.is_closing and std.mem.eql(u8, inner.name, "list")) break;
            if (inner.is_closing) continue;
            length_expr = parseExprTag(ctx, arena, inner);
            skipUntilClose(ctx, "list");
            break;
        }
    }
    return .{
        .name = reqAttr(ctx, tag, "name"),
        .type = reqAttr(ctx, tag, "type"),
        .enum_ref = tag.getAttr("enum"),
        .mask_ref = tag.getAttr("mask"),
        .length_expr = length_expr,
    };
}

fn parseSwitch(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) Switch {
    var expr: ?*const Expr = null;
    var cases: std.ArrayListUnmanaged(Case) = .empty;
    var is_bitcase = false;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "switch")) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "bitcase")) {
            is_bitcase = true;
            cases.append(arena, parseCase(ctx, arena, tag, "bitcase")) catch oom();
        } else if (std.mem.eql(u8, tag.name, "case")) {
            cases.append(arena, parseCase(ctx, arena, tag, "case")) catch oom();
        } else if (std.mem.eql(u8, tag.name, "required_start_align")) {
            // Alignment annotation inside switch
        } else {
            if (expr != null) {
                ctx.fail("unrecognized tag in switch: '{s}'", .{tag.name});
            }
            expr = parseExprTag(ctx, arena, tag);
        }
    }
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .expr = expr orelse ctx.fail("switch missing expression", .{}),
        .cases = cases.toOwnedSlice(arena) catch oom(),
        .is_bitcase = is_bitcase,
    };
}

fn parseCase(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag, close_tag_name: []const u8) Case {
    var exprs: std.ArrayListUnmanaged(*const Expr) = .empty;
    var members: std.ArrayListUnmanaged(StructMember) = .empty;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, close_tag_name)) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "enumref")) {
            const ref = reqAttr(ctx, tag, "ref");
            const name = ctx.parser.getTextUntilClose("enumref");
            const expr_node = arena.create(Expr) catch oom();
            expr_node.* = .{ .enumref = .{ .ref = ref, .name = name } };
            exprs.append(arena, expr_node) catch oom();
        } else if (std.mem.eql(u8, tag.name, "value")) {
            const text = ctx.parser.getTextUntilClose("value");
            const expr_node = arena.create(Expr) catch oom();
            expr_node.* = .{ .value = std.fmt.parseInt(i64, text, 0) catch
                ctx.fail("invalid value: '{s}'", .{text}) };
            exprs.append(arena, expr_node) catch oom();
        } else {
            if (parseMember(ctx, arena, tag)) |member| {
                members.append(arena, member) catch oom();
            }
        }
    }
    return .{
        .name = open_tag.getAttr("name"),
        .exprs = exprs.toOwnedSlice(arena) catch oom(),
        .members = members.toOwnedSlice(arena) catch oom(),
    };
}

fn parseRequest(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) Request {
    var members: std.ArrayListUnmanaged(StructMember) = .empty;
    var reply: ?[]const StructMember = null;
    if (!open_tag.self_closing) {
        while (ctx.parser.nextTag()) |tag| {
            if (tag.is_closing and std.mem.eql(u8, tag.name, "request")) break;
            if (tag.is_closing) continue;
            if (std.mem.eql(u8, tag.name, "reply")) {
                reply = parseStructMembers(ctx, arena, "reply");
            } else {
                if (parseMember(ctx, arena, tag)) |member| {
                    members.append(arena, member) catch oom();
                }
            }
        }
    }
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .opcode = parseU16(ctx, reqAttr(ctx, open_tag, "opcode")),
        .combine_adjacent = if (open_tag.getAttr("combine-adjacent")) |v| std.mem.eql(u8, v, "true") else false,
        .members = members.toOwnedSlice(arena) catch oom(),
        .reply = reply,
    };
}

fn parseEvent(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) Event {
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .number = parseU16(ctx, reqAttr(ctx, open_tag, "number")),
        .no_sequence_number = if (open_tag.getAttr("no-sequence-number")) |v| std.mem.eql(u8, v, "true") else false,
        .is_xge = if (open_tag.getAttr("xge")) |v| std.mem.eql(u8, v, "true") else false,
        .members = if (open_tag.self_closing) &.{} else parseStructMembers(ctx, arena, "event"),
    };
}

fn parseEventStruct(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) EventStruct {
    var alloweds: std.ArrayListUnmanaged(EventStructAllowed) = .empty;
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, "eventstruct")) break;
        if (tag.is_closing) continue;
        if (std.mem.eql(u8, tag.name, "allowed")) {
            alloweds.append(arena, .{
                .extension = reqAttr(ctx, tag, "extension"),
                .is_xge = if (tag.getAttr("xge")) |v| std.mem.eql(u8, v, "true") else false,
                .opcode_min = parseU16(ctx, reqAttr(ctx, tag, "opcode-min")),
                .opcode_max = parseU16(ctx, reqAttr(ctx, tag, "opcode-max")),
            }) catch oom();
        } else {
            ctx.fail("unrecognized tag in eventstruct: '{s}'", .{tag.name});
        }
    }
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .alloweds = alloweds.toOwnedSlice(arena) catch oom(),
    };
}

fn parseError(ctx: *Context, arena: std.mem.Allocator, open_tag: xml.Tag) XError {
    return .{
        .name = reqAttr(ctx, open_tag, "name"),
        .number = if (open_tag.getAttr("number")) |n|
            std.fmt.parseInt(i32, n, 10) catch ctx.fail("invalid error number: '{s}'", .{n})
        else
            ctx.fail("error missing number attr", .{}),
        .members = if (open_tag.self_closing) &.{} else parseStructMembers(ctx, arena, "error"),
    };
}

fn parseExpr(ctx: *Context, arena: std.mem.Allocator, close_tag_name: []const u8) *const Expr {
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing) {
            if (std.mem.eql(u8, tag.name, close_tag_name)) {
                ctx.fail("expected expression in <{s}>, got closing tag", .{close_tag_name});
            }
            continue;
        }
        const expr = parseExprTag(ctx, arena, tag);
        skipUntilClose(ctx, close_tag_name);
        return expr;
    }
    ctx.fail("unexpected end of input while parsing expression", .{});
}

fn skipUntilClose(ctx: *Context, tag_name: []const u8) void {
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing and std.mem.eql(u8, tag.name, tag_name)) return;
    }
}

fn parseNextExprTag(ctx: *Context, arena: std.mem.Allocator) *const Expr {
    while (ctx.parser.nextTag()) |tag| {
        if (tag.is_closing) continue;
        return parseExprTag(ctx, arena, tag);
    }
    ctx.fail("unexpected end of input while parsing expression", .{});
}

fn parseExprTag(ctx: *Context, arena: std.mem.Allocator, tag: xml.Tag) *const Expr {
    const expr = arena.create(Expr) catch oom();
    if (std.mem.eql(u8, tag.name, "fieldref")) {
        expr.* = .{ .fieldref = ctx.parser.getTextUntilClose("fieldref") };
    } else if (std.mem.eql(u8, tag.name, "value")) {
        const text = ctx.parser.getTextUntilClose("value");
        expr.* = .{ .value = std.fmt.parseInt(i64, text, 0) catch
            ctx.fail("invalid value: '{s}'", .{text}) };
    } else if (std.mem.eql(u8, tag.name, "op")) {
        const operator = reqAttr(ctx, tag, "op");
        const lhs = parseNextExprTag(ctx, arena);
        const rhs = parseNextExprTag(ctx, arena);
        skipUntilClose(ctx, "op");
        expr.* = .{ .op = .{ .operator = operator, .lhs = lhs, .rhs = rhs } };
    } else if (std.mem.eql(u8, tag.name, "unop")) {
        const operator = reqAttr(ctx, tag, "op");
        const operand = parseNextExprTag(ctx, arena);
        skipUntilClose(ctx, "unop");
        expr.* = .{ .unop = .{ .operator = operator, .operand = operand } };
    } else if (std.mem.eql(u8, tag.name, "popcount")) {
        const operand = parseNextExprTag(ctx, arena);
        skipUntilClose(ctx, "popcount");
        expr.* = .{ .popcount = operand };
    } else if (std.mem.eql(u8, tag.name, "sumof")) {
        const ref = reqAttr(ctx, tag, "ref");
        if (tag.self_closing) {
            expr.* = .{ .sumof = .{ .ref = ref, .operand = null } };
        } else {
            const operand = parseNextExprTag(ctx, arena);
            skipUntilClose(ctx, "sumof");
            expr.* = .{ .sumof = .{ .ref = ref, .operand = operand } };
        }
    } else if (std.mem.eql(u8, tag.name, "paramref")) {
        const param_type = reqAttr(ctx, tag, "type");
        const name = ctx.parser.getTextUntilClose("paramref");
        expr.* = .{ .paramref = .{ .type = param_type, .name = name } };
    } else if (std.mem.eql(u8, tag.name, "enumref")) {
        const ref = reqAttr(ctx, tag, "ref");
        const name = ctx.parser.getTextUntilClose("enumref");
        expr.* = .{ .enumref = .{ .ref = ref, .name = name } };
    } else if (std.mem.eql(u8, tag.name, "listelement-ref")) {
        expr.* = .{ .listelement_ref = {} };
    } else if (std.mem.eql(u8, tag.name, "length")) {
        if (!tag.self_closing) skipUntilClose(ctx, "length");
        expr.* = .{ .list_length = {} };
    } else {
        ctx.fail("unrecognized expression tag: '{s}'", .{tag.name});
    }
    return expr;
}

// ============================================================================
// XID type mapping
// ============================================================================

const XidType = enum {
    Window,
    Pixmap,
    Cursor,
    Font,
    GraphicsContext,
    Colormap,
    Atom,
    Drawable,
    Fontable,
    Damage,
    Alarm,
    Counter,
    Fence,
    Barrier,
    SyncObj,
    Context,
    PBuffer,
    FbConfig,
    GlyphSet,
    Picture,
    PictFormat,
    Region,
    Crtc,
    Mode,
    Output,
    Provider,
    Lease,
    Seg,
    Event,
    PContext,
    Port,
    Encoding,
    Surface,
    Subpicture,

    const map = std.StaticStringMap(XidType).initComptime(.{
        .{ "WINDOW", .Window },
        .{ "PIXMAP", .Pixmap },
        .{ "CURSOR", .Cursor },
        .{ "FONT", .Font },
        .{ "GCONTEXT", .GraphicsContext },
        .{ "COLORMAP", .Colormap },
        .{ "ATOM", .Atom },
        .{ "DRAWABLE", .Drawable },
        .{ "FONTABLE", .Fontable },
        .{ "DAMAGE", .Damage },
        .{ "ALARM", .Alarm },
        .{ "COUNTER", .Counter },
        .{ "FENCE", .Fence },
        .{ "BARRIER", .Barrier },
        .{ "SYNCOBJ", .SyncObj },
        .{ "CONTEXT", .Context },
        .{ "PBUFFER", .PBuffer },
        .{ "FBCONFIG", .FbConfig },
        .{ "GLYPHSET", .GlyphSet },
        .{ "PICTURE", .Picture },
        .{ "PICTFORMAT", .PictFormat },
        .{ "REGION", .Region },
        .{ "CRTC", .Crtc },
        .{ "MODE", .Mode },
        .{ "OUTPUT", .Output },
        .{ "PROVIDER", .Provider },
        .{ "LEASE", .Lease },
        .{ "SEG", .Seg },
        .{ "EVENT", .Event },
        .{ "PCONTEXT", .PContext },
        .{ "PORT", .Port },
        .{ "ENCODING", .Encoding },
        .{ "SURFACE", .Surface },
        .{ "SUBPICTURE", .Subpicture },
    });

    fn fromString(name: []const u8) XidType {
        return map.get(name) orelse std.debug.panic("unknown xidtype: '{s}'", .{name});
    }

    fn zeroName(self: XidType) []const u8 {
        return switch (self) {
            .Colormap => "copy_from_parent",
            else => "none",
        };
    }
};

// ============================================================================
// Code generation
// ============================================================================

fn generate(w: *std.Io.Writer, protocols: []const Protocol) error{WriteFailed}!void {
    try w.writeAll(
        \\// Auto-generated by xcb-scanner. Do not edit.
        \\
        \\
    );

    for (protocols) |proto| {
        try w.print("// Protocol: {s}\n", .{proto.header});
        if (proto.extension_xname) |xname| {
            try w.print("// Extension: {s}\n", .{xname});
        }
        try w.writeAll("\n");

        for (proto.xidtypes) |name| {
            try generateXidType(w, name, proto.xidunions);
        }

        for (proto.xidunions) |xid_union| {
            try generateXidType(w, xid_union.name, &.{});
        }

        for (proto.typedefs) |td| {
            try w.print("pub const {s} = {s};\n", .{ td.newname, mapBaseType(td.oldname) });
        }

        if (proto.xidtypes.len > 0 or proto.xidunions.len > 0 or proto.typedefs.len > 0) {
            try w.writeAll("\n");
        }

        for (proto.enums) |e| {
            try generateEnum(w, e);
        }

        for (proto.structs) |s| {
            try generateStruct(w, s);
        }

        for (proto.unions) |u| {
            try w.print("pub const {s} = extern union {{\n", .{u.name});
            for (u.members) |member| {
                switch (member) {
                    .field => |f| try w.print("    {s}: {s},\n", .{ f.name, mapType(f.type) }),
                    .list => |l| try generateUnionList(w, l),
                    .pad => {},
                    else => try w.print("    // TODO: unhandled union member\n", .{}),
                }
            }
            try w.writeAll("};\n\n");
        }

        for (proto.requests) |req| {
            try generateRequest(w, proto, req);
        }

        for (proto.events) |ev| {
            try generateEvent(w, ev);
        }

        for (proto.eventcopies) |ec| {
            try w.print("pub const {s}Event = {s}Event;\n", .{ ec.name, ec.ref });
        }

        for (proto.errors) |err| {
            try w.print("pub const {s}Error = struct {{\n", .{err.name});
            try generateStructFields(w, err.members);
            try w.writeAll("};\n\n");
        }

        for (proto.errorcopies) |ec| {
            try w.print("pub const {s}Error = {s}Error;\n", .{ ec.name, ec.ref });
        }
    }

    try w.flush();
}

fn generateXidType(w: *std.Io.Writer, name: []const u8, xidunions: []const XidUnion) error{WriteFailed}!void {
    const xid = XidType.fromString(name);
    const zig_name = @tagName(xid);
    try w.print("pub const {s} = enum(u32) {{\n", .{zig_name});
    try w.print("    {s} = 0,\n", .{xid.zeroName()});
    try w.writeAll("    _,\n");
    try w.writeAll("\n");
    try w.print("    pub fn fromInt(i: u32) {s} {{\n", .{zig_name});
    try w.writeAll("        return @enumFromInt(i);\n");
    try w.writeAll("    }\n");

    // Generate conversion methods for each xidunion this type belongs to
    for (xidunions) |xid_union| {
        for (xid_union.types) |member_type| {
            if (std.mem.eql(u8, member_type, name)) {
                const union_xid = XidType.fromString(xid_union.name);
                const union_zig_name = @tagName(union_xid);
                try w.print("\n    pub fn {c}{s}(self: {s}) {s} {{\n", .{ std.ascii.toLower(union_zig_name[0]), union_zig_name[1..], zig_name, union_zig_name });
                try w.writeAll("        return @enumFromInt(@intFromEnum(self));\n");
                try w.writeAll("    }\n");
                break;
            }
        }
    }

    try w.print("\n    pub fn format(v: {s}, writer: *std.Io.Writer) error{{WriteFailed}}!void {{\n", .{zig_name});
    try w.writeAll("        switch (v) {\n");
    try w.print("            .{s} => try writer.writeAll(\".{0s}\"),\n", .{xid.zeroName()});
    try w.writeAll("            _ => |d| try writer.print(\"{d}\", .{d}),\n");
    try w.writeAll("        }\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n\n");
}

fn generateEnum(w: *std.Io.Writer, e: Enum) error{WriteFailed}!void {
    var all_bits = true;
    for (e.items) |item| {
        switch (item.value) {
            .bit => {},
            .value => all_bits = false,
        }
    }

    if (all_bits) {
        try w.print("pub const {s} = struct {{\n", .{e.name});
        for (e.items) |item| {
            switch (item.value) {
                .bit => |b| try w.print("    pub const {s}: u32 = 1 << {};\n", .{ item.name, b }),
                .value => |v| try w.print("    pub const {s}: u32 = {};\n", .{ item.name, v }),
            }
        }
        try w.writeAll("};\n\n");
    } else {
        var has_dupes = false;
        for (e.items, 0..) |item, i| {
            for (e.items[0..i]) |prev| {
                if (enumItemValue(item) == enumItemValue(prev)) {
                    has_dupes = true;
                    break;
                }
            }
            if (has_dupes) break;
        }

        if (has_dupes) {
            try w.print("pub const {s} = struct {{\n", .{e.name});
            for (e.items) |item| {
                try w.print("    pub const {s}: u32 = {};\n", .{ item.name, enumItemValue(item) });
            }
            try w.writeAll("};\n\n");
        } else {
            try w.print("pub const {s} = enum(u32) {{\n", .{e.name});
            for (e.items) |item| {
                try w.print("    {s} = {},\n", .{ item.name, enumItemValue(item) });
            }
            try w.writeAll("    _,\n");
            try w.writeAll("};\n\n");
        }
    }
}

fn enumItemValue(item: EnumItem) i64 {
    return switch (item.value) {
        .value => |v| v,
        .bit => |b| @as(i64, 1) << b,
    };
}

fn generateStruct(w: *std.Io.Writer, s: Struct) error{WriteFailed}!void {
    try w.print("pub const {s} = struct {{\n", .{s.name});
    try generateStructFields(w, s.members);
    try w.writeAll("};\n\n");
}

fn generateStructFields(w: *std.Io.Writer, members: []const StructMember) error{WriteFailed}!void {
    for (members) |member| {
        switch (member) {
            .field => |f| try w.print("    {s}: {s},\n", .{ f.name, mapType(f.type) }),
            .pad => |p| switch (p) {
                .bytes => |b| try w.print("    _pad: [{d}]u8 = undefined,\n", .{b}),
                .@"align" => try w.print("    // pad align\n", .{}),
            },
            .list => |l| {
                if (l.length_expr) |_| {
                    try w.print("    // list: {s} (type {s}, variable length)\n", .{ l.name, l.type });
                } else {
                    try w.print("    // list: {s} (type {s})\n", .{ l.name, l.type });
                }
            },
            .fd => |name| try w.print("    // fd: {s}\n", .{name}),
            .@"switch" => |sw| try w.print("    // switch: {s}\n", .{sw.name}),
            .exprfield => |ef| try w.print("    // exprfield: {s}\n", .{ef.name}),
            .required_start_align => |a| try w.print("    // required_start_align: align={d}, offset={d}\n", .{ a.@"align", a.offset }),
            .value_param => |vp| try w.print("    // valueparam: mask={s}, list={s}\n", .{ vp.value_mask_name, vp.value_list_name }),
        }
    }
}

fn generateUnionList(w: *std.Io.Writer, l: List) error{WriteFailed}!void {
    if (l.length_expr) |expr| {
        switch (expr.*) {
            .value => |v| {
                try w.print("    {s}: [{d}]{s},\n", .{ l.name, v, mapType(l.type) });
                return;
            },
            else => {},
        }
    }
    try w.print("    // list: {s} (type {s})\n", .{ l.name, l.type });
}

fn generateRequest(w: *std.Io.Writer, proto: Protocol, req: Request) error{WriteFailed}!void {
    try w.print("pub const {s}Request = struct {{\n", .{req.name});
    try w.print("    pub const opcode = {};\n", .{req.opcode});
    if (proto.extension_xname) |xname| {
        try w.print("    pub const extension = \"{s}\";\n", .{xname});
    }
    try generateStructFields(w, req.members);
    try w.writeAll("};\n\n");

    if (req.reply) |reply_members| {
        try w.print("pub const {s}Reply = struct {{\n", .{req.name});
        try generateStructFields(w, reply_members);
        try w.writeAll("};\n\n");
    }
}

fn generateEvent(w: *std.Io.Writer, ev: Event) error{WriteFailed}!void {
    try w.print("pub const {s}Event = struct {{\n", .{ev.name});
    try w.print("    pub const number = {};\n", .{ev.number});
    if (ev.no_sequence_number) {
        try w.writeAll("    pub const no_sequence_number = true;\n");
    }
    if (ev.is_xge) {
        try w.writeAll("    pub const is_xge = true;\n");
    }
    try generateStructFields(w, ev.members);
    try w.writeAll("};\n\n");
}

fn mapBaseType(xcb_type: []const u8) []const u8 {
    if (std.mem.eql(u8, xcb_type, "CARD8")) return "u8";
    if (std.mem.eql(u8, xcb_type, "CARD16")) return "u16";
    if (std.mem.eql(u8, xcb_type, "CARD32")) return "u32";
    if (std.mem.eql(u8, xcb_type, "CARD64")) return "u64";
    if (std.mem.eql(u8, xcb_type, "INT8")) return "i8";
    if (std.mem.eql(u8, xcb_type, "INT16")) return "i16";
    if (std.mem.eql(u8, xcb_type, "INT32")) return "i32";
    if (std.mem.eql(u8, xcb_type, "INT64")) return "i64";
    if (std.mem.eql(u8, xcb_type, "BYTE")) return "u8";
    if (std.mem.eql(u8, xcb_type, "BOOL")) return "u8";
    if (std.mem.eql(u8, xcb_type, "char")) return "u8";
    if (std.mem.eql(u8, xcb_type, "float")) return "f32";
    if (std.mem.eql(u8, xcb_type, "double")) return "f64";
    if (std.mem.eql(u8, xcb_type, "void")) return "u8";
    return xcb_type;
}

fn mapType(xcb_type: []const u8) []const u8 {
    return mapBaseType(xcb_type);
}

// ============================================================================
// Helpers
// ============================================================================

fn reqAttr(ctx: *const Context, tag: xml.Tag, name: []const u8) []const u8 {
    return tag.getAttr(name) orelse
        ctx.fail("{s} element missing '{s}' attribute", .{ tag.name, name });
}

fn parseU16(ctx: *const Context, s: []const u8) u16 {
    return std.fmt.parseInt(u16, s, 10) catch
        ctx.fail("invalid u16: '{s}'", .{s});
}

fn parseU32(ctx: *const Context, s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 10) catch
        ctx.fail("invalid u32: '{s}'", .{s});
}

fn oom() noreturn {
    @panic("out of memory");
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const xml = @import("xml.zig");
