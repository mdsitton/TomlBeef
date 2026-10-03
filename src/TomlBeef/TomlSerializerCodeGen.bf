using System;
using System.Collections;
using System.Reflection;
using FormatCore.Mapping;
using internal FormatCore;

namespace TomlBeef;

/// @brief The compile-time half of [TomlObject]: writes the Beef source of a type's TomlRead and
/// TomlWrite and hands it to the compiler. Nothing here runs in the finished program; the emitted code
/// calls TomlBind for the per-value work.
///
/// Emitted names are fully qualified (the user's file needs no `using TomlBeef`), fields are reached
/// through `this.` and locals start with `_`, so neither clashes with the type's own members.
/// Enums are matched with generated switches over their case names, so they need no reflection data
/// at run time.
public static class TomlSerializerCodeGen
{
	enum Kind
	{
		Unsupported,
		Bool,
		Integer,
		Float,
		String,
		Enum,
		OffsetDateTime,
		LocalDateTime,
		LocalDate,
		LocalTime,
		Object,
		List,
		/// Dictionary<String, T>: a table whose keys are the dictionary's
		Dictionary,
		/// An ITomlConverter<T>: from [TomlUseConverter] on the field, or registered with [TomlConverter]
		Converter
	}

	/// The user-side comptime entry FormatCore's MappingDriver emits into every [TomlObject] type.
	const String cEntry = "TomlGen_";

	/// @brief Emit ITomlSerializable, TomlKey, TomlKeyAliases and the signatures of TomlRead and TomlWrite
	/// into `type` (ApplyToType). The two bodies are planned and written later, when the methods are
	/// compiled, through the [Comptime] entry emitted into the type (FormatCore's MappingDriver):
	/// converter lookups then see the user's project and its dependencies, however many projects use
	/// TomlBeef, and a type can hold itself (`List<Node> children`).
	/// @param type A class or struct carrying [TomlObject].
	/// @param naming How field names (and the type name, for the key) become keys.
	/// @param homeKey The type's table in a document (TomlObjectAttribute.Key), or empty for its name.
	[Comptime]
	public static void Emit(Type type, TomlKeyNaming naming, StringView homeKey)
	{
		let code = scope String();

		// A [TomlObject] base already has both methods: hide them (each level reads and writes its own
		// fields after calling its base's)
		bool baseIsObject = BaseIsObject(type);
		StringView hide = baseIsObject ? "new " : "";
		// The unspecialized pass of a generic type: stub bodies (each specialization gets its own pass)
		bool open = MappingDriver.IsOpenType(type);
		if (!open)
			MappingDriver.EmitEntry(type, cEntry, "TomlBeef.TomlSerializerCodeGen.Body", baseIsObject);

		// Where path-less TomlDocument.Deserialize/Serialize find the type: its Key, or its own name
		let home = scope String();
		if (!homeKey.IsEmpty)
			home.Append(homeKey);
		else
			ApplyNaming(type.GetName(.. scope .()), naming, home);
		let homeLiteral = AppendLiteral(.. scope .(), home);
		code.AppendF("public {}static StringView TomlKey => {};\n", hide, homeLiteral);
		// Older paths of the type's table, from [TomlAlias] on the type
		let typeAliases = scope String();
		int aliasCount = 0;
		for (let alias in type.GetCustomAttributes<TomlAliasAttribute>())
		{
			if (aliasCount++ > 0)
				typeAliases.Append(", ");
			AppendLiteral(typeAliases, alias.mName);
		}
		if (aliasCount == 0)
			code.AppendF("public {}static Span<StringView> TomlKeyAliases => default;\n", hide);
		else
		{
			code.AppendF("static StringView[{}] sTomlKeyAliases = .({});\n", aliasCount, typeAliases);
			code.AppendF("public {}static Span<StringView> TomlKeyAliases => sTomlKeyAliases;\n", hide);
		}
		code.AppendF("public {}Result<void, TomlBeef.TomlParseError> TomlRead(TomlBeef.TomlTable _table, System.ITypedAllocator _alloc = null){}\n{{\n", hide, type.IsValueType ? " mut" : "");
		AppendPart(code, open, 0);
		code.AppendF("}}\npublic {}Result<void, TomlBeef.TomlParseError> TomlWrite(TomlBeef.TomlTable _table)\n{{\n", hide);
		AppendPart(code, open, 1);
		code.Append("}\n");

		Compiler.EmitAddInterface(type, typeof(ITomlSerializable));
		Compiler.EmitTypeBody(type, code);
	}

	/// A generated method's body: the mixin of `part` (or, for an open generic type, a stub).
	[Comptime]
	static void AppendPart(String code, bool open, int part)
	{
		if (open)
			code.Append("\treturn .Ok;\n");
		else
			MappingDriver.AppendBody(code, "\t", cEntry, part);
	}

	[Comptime]
	static bool BaseIsObject(Type type)
	{
		return type.BaseType != null && type.BaseType != typeof(Object) && type.BaseType.HasCustomAttribute<TomlObjectAttribute>();
	}

	/// @brief The body of TomlRead (`part` 0) or TomlWrite (1) of `type`, mixed in when the method is
	/// compiled (through the [Comptime] entry Emit put into the type, so converter lookups see the user's
	/// project).
	/// @param type The [TomlObject] type.
	/// @param part 0: TomlRead, 1: TomlWrite.
	/// @param args Unused.
	/// @return The code.
	[Comptime]
	public static String Body(Type type, int part, String args)
	{
		var naming = TomlKeyNaming.AsDeclared;
		if (type.GetCustomAttribute<TomlObjectAttribute>() case .Ok(let attribute))
			naming = attribute.Naming;
		let read = new String();
		let write = scope String();
		if (BaseIsObject(type))
		{
			read.Append("\tTry!(base.TomlRead(_table, _alloc));\n");
			write.Append("\tTry!(base.TomlWrite(_table));\n");
		}

		for (let field in type.GetFields())
		{
			if (field.DeclaringType != type || field.IsStatic || field.IsConst || !field.IsPublic || field.HasCustomAttribute<TomlIgnoreAttribute>())
				continue;

			let key = scope String();
			if (field.GetCustomAttribute<TomlNameAttribute>() case .Ok(let named))
				AppendLiteral(key, named.mName);
			else
				AppendLiteral(key, ApplyNaming(field.Name, naming, .. scope .()));
			bool required = field.HasCustomAttribute<TomlRequiredAttribute>();

			let fieldType = field.FieldType;
			Type converter = null;
			var kind = Kind.Converter;
			if (field.GetCustomAttribute<TomlUseConverterAttribute>() case .Ok(let use))
				converter = use.mConverter;
			else
				kind = Classify(fieldType, out converter);
			// Lists of lists, and dictionaries inside lists or dictionaries, are left for later
			if (!IsSupported(kind, fieldType))
			{
				let typeName = fieldType.GetFullName(.. scope .());
				let ownerName = type.GetFullName(.. scope .());
				Runtime.FatalError(scope $"[TomlObject] {ownerName}.{field.Name}: TOML serialization does not support fields of type {typeName}. Supported: bool, integers, float, double, String, enums, the TOML date/time types, [TomlObject] types, List<T> of those, Dictionary<String, T> of those (a table with free keys), and types with a converter ([TomlConverter] registration or [TomlUseConverter] on the field). Mark the field [TomlIgnore] to leave it out.");
			}

			// Older names from [TomlAlias], as `, "a", "b"` to append to a call's arguments
			let aliases = scope String();
			for (let alias in field.GetCustomAttributes<TomlAliasAttribute>())
				AppendLiteral(aliases..Append(", "), alias.mName);

			let target = scope $"this.{field.Name}";
			EmitRead(read, target, key, aliases, required, fieldType, kind, converter);
			if (!aliases.IsEmpty)
				write.AppendF("\tTomlBeef.TomlBind.RenameAlias(_table, {}{});\n", key, aliases);
			EmitWrite(write, target, key, fieldType, kind, converter);
		}

		read.Append("\treturn .Ok;\n");
		write.Append("\treturn .Ok;\n");
		if (part == 1)
			read.Set(write);
		return read;
	}

	/// How a field or list item of `type` is handled. The TOML scalar types are fixed; any other type
	/// takes a registered converter first, then the built-in enum, object and List handling.
	[Comptime]
	static Kind Classify(Type type, out Type converter)
	{
		converter = null;
		if (type == typeof(bool))
			return .Bool;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32))
			return .Unsupported;
		if (type.IsInteger)
			return .Integer;
		if (type == typeof(float) || type == typeof(double))
			return .Float;
		if (type == typeof(String))
			return .String;
		if (type == typeof(TomlOffsetDateTime))
			return .OffsetDateTime;
		if (type == typeof(TomlLocalDateTime))
			return .LocalDateTime;
		if (type == typeof(TomlLocalDate))
			return .LocalDate;
		if (type == typeof(TomlLocalTime))
			return .LocalTime;
		converter = FindRegisteredConverter(type);
		if (converter != null)
			return .Converter;
		// Simple enums only: cases with payloads have no single name to write
		if (type.IsEnum && !type.IsUnion)
			return .Enum;
		if (type.HasCustomAttribute<TomlObjectAttribute>())
			return .Object;
		if (ListElement(type) != null)
			return .List;
		if (DictionaryValue(type) != null)
			return .Dictionary;
		return .Unsupported;
	}

	/// Whether a field (or a dictionary value) of `kind` can be generated: its list items or dictionary
	/// values must be supported, and not themselves lists or dictionaries.
	[Comptime]
	static bool IsSupported(Kind kind, Type type)
	{
		Kind inner = .Bool;
		if (kind == .List)
			inner = Classify(ListElement(type), ?);
		else if (kind == .Dictionary)
		{
			inner = Classify(DictionaryValue(type), ?);
			// A dictionary of lists is fine (each value an array); of lists of lists or dictionaries not
			if (inner == .List)
				return IsSupported(inner, DictionaryValue(type));
		}
		return kind != .Unsupported && inner != .Unsupported && inner != .Dictionary && (kind != .List || inner != .List);
	}

	/// The T of a Dictionary<String, T>, or null (other key types are not supported: TOML keys are text).
	[Comptime]
	static Type DictionaryValue(Type type)
	{
		if (TypeShapes.DictionaryKey(type) == typeof(String))
			return TypeShapes.DictionaryValue(type);
		return null;
	}

	/// The converter registered with [TomlConverter(typeof(target))] that the type being compiled can see
	/// (declared in its project or a dependency), or null. Two such registrations stop the build. Only in
	/// the mixin stage (Body): there "current" is the user's project, and FormatCore's Registry.IsVisible
	/// is the user's project and its dependencies (inside ApplyToType the user's declarations were seen
	/// only while the user's project was TomlBeef's only dependent: FormatCore bug B1).
	[Comptime]
	static Type FindRegisteredConverter(Type target)
	{
		Type found = null;
		for (let declaration in Type.TypeDeclarations)
		{
			if (!Registry.IsVisible(declaration))
				continue;
			if (!(declaration.GetCustomAttribute<TomlConverterAttribute>() case .Ok(let registration)) || registration.mTarget != target)
				continue;
			let converter = declaration.ResolvedType;
			if (found != null && found != converter)
			{
				let targetName = target.GetFullName(.. scope .());
				Runtime.FatalError(scope $"[TomlConverter] Both {found.GetFullName(.. scope .())} and {converter.GetFullName(.. scope .())} are registered for {targetName}. Keep one, or pick one per field with [TomlUseConverter].");
			}
			found = converter;
		}
		return found;
	}

	/// The T of a List<T>, or null.
	[Comptime]
	static Type ListElement(Type type) => TypeShapes.ListElement(type);

	/// Appends the key for field `name` (FormatCore's Naming: words split at case changes, keeping
	/// acronyms together, `HTTPPort` as HTTP, Port and `Utf8Name` as Utf8, Name; underscores also split).
	[Comptime]
	static void ApplyNaming(StringView name, TomlKeyNaming naming, String key)
	{
		Naming.Apply(name, naming, key);
	}

	/// Appends `text` as a Beef string literal (FormatCore's Literal). Keys are ordinary text; control
	/// characters, which a field name cannot hold and a TomlName has no reason to, stop the build.
	[Comptime]
	static void AppendLiteral(String code, StringView text)
	{
		for (let c in text.RawChars)
		{
			if ((uint8)c < 0x20)
				Runtime.FatalError(scope $"[TomlName] \"{text}\" contains a control character");
		}
		Literal.Append(code, text);
	}

	/// The smallest and largest value of an integer type, as int64 source expressions (FormatCore's
	/// IntegerBounds). TOML integers are int64, so 64-bit unsigned types read up to int64.MaxValue, from 0.
	[Comptime]
	static void IntegerRange(Type type, String min, String max)
	{
		IntegerBounds.Range(type, min, max);
	}

	/// "A, B, C": the enum's case names, for error messages.
	[Comptime]
	static void CaseList(Type enumType, String outList)
	{
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			if (!outList.IsEmpty)
				outList.Append(", ");
			outList.Append(field.Name);
		}
	}

	/// `case "A": target = .A;` for each case, then a default that returns `error`.
	[Comptime]
	static void EmitCaseMatch(String code, Type enumType, StringView indent, StringView subject, StringView assignPrefix, StringView assignSuffix, StringView error)
	{
		code.AppendF("{}switch ({})\n{}{{\n", indent, subject, indent);
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			code.AppendF("{}case ", indent);
			AppendLiteral(code, field.Name);
			code.AppendF(": {}.{}{};\n", assignPrefix, field.Name, assignSuffix);
		}
		code.AppendF("{}default: return .Err({});\n{}}}\n", indent, error, indent);
	}

	/// Appends the reading of one value into `name`, an assignable expression (`this.Port`, or a
	/// dictionary slot `this.Colors[_dkey]`), from key `literalKey` (a literal or an expression) of `_table`.
	[Comptime]
	static void EmitRead(String code, StringView name, StringView literalKey, StringView aliases, bool required, Type type, Kind kind, Type converter)
	{
		StringView req = required ? "true" : "false";
		code.Append("\t{\n");
		// With aliases, the key is whichever name the table has: the current one first
		StringView key = literalKey;
		if (!aliases.IsEmpty)
		{
			code.AppendF("\t\tlet _k = TomlBeef.TomlBind.FindKey(_table, {}{});\n", literalKey, aliases);
			key = "_k";
		}
		switch (kind)
		{
		case .Integer:
			let min = scope String();
			let max = scope String();
			IntegerRange(type, min, max);
			code.AppendF("\t\tint64 _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadInteger(_table, {}, {}, {}, {}, out _v)))\n\t\t\t{} = (.)_v;\n", key, req, min, max, name);
		case .Float:
			code.AppendF("\t\tdouble _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadFloat(_table, {}, {}, out _v)))\n\t\t\t{} = (.)_v;\n", key, req, name);
		case .Bool:
			code.AppendF("\t\tbool _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadBool(_table, {}, {}, out _v)))\n\t\t\t{} = _v;\n", key, req, name);
		case .String:
			code.AppendF("\t\tStringView _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadString(_table, {}, {}, out _v)))\n\t\t{{\n", key, req);
			code.AppendF("\t\t\tif ({0} == null)\n\t\t\t\t{0} = {1};\n\t\t\telse\n\t\t\t\t{0}.Set(_v);\n\t\t}}\n", name, NewExpr("String", "_v", .. scope .()));
		case .Enum:
			let cases = scope String();
			CaseList(type, cases);
			code.AppendF("\t\tStringView _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadString(_table, {}, {}, out _v)))\n", key, req);
			let error = scope $"TomlBeef.TomlBind.UnknownCase(_table, {key}, _v, \"{cases}\")";
			EmitCaseMatch(code, type, "\t\t", "_v", scope $"{name} = ", "", error);
		case .OffsetDateTime, .LocalDateTime, .LocalDate, .LocalTime:
			code.AppendF("\t\tTry!(TomlBeef.TomlBind.ReadDateTime(_table, {}, {}, ref {}));\n", key, req, name);
		case .Object:
			code.AppendF("\t\tTomlBeef.TomlTable _t;\n\t\tif (Try!(TomlBeef.TomlBind.ReadTable(_table, {}, {}, out _t)))\n\t\t{{\n", key, req);
			if (!type.IsValueType)
				code.AppendF("\t\t\tif ({0} == null)\n\t\t\t\t{0} = {1};\n", name, NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
			code.AppendF("\t\t\tTry!({}.TomlRead(_t, _alloc));\n\t\t}}\n", name);
		case .List:
			let element = ListElement(type);
			let elementKind = Classify(element, let elementConverter);
			code.AppendF("\t\tTomlBeef.TomlArray _a;\n\t\tif (Try!(TomlBeef.TomlBind.ReadArray(_table, {}, {}, out _a)))\n\t\t{{\n", key, req);
			code.AppendF("\t\t\tif ({0} == null)\n\t\t\t\t{0} = {1};\n", name, NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
			// Without an allocator the list owns its object items (Strings, objects, converted classes):
			// delete them before replacing. With one, the allocator owns what reads create.
			if (!element.IsValueType)
				code.AppendF("\t\t\tif (_alloc == null)\n\t\t\t{{\n\t\t\t\tfor (let _old in {})\n\t\t\t\t\tdelete _old;\n\t\t\t}}\n", name);
			code.AppendF("\t\t\t{}.Clear();\n\t\t\tfor (int _i < _a.Count)\n\t\t\t{{\n", name);
			EmitReadElement(code, name, element, elementKind, elementConverter);
			code.Append("\t\t\t}\n\t\t}\n");
		case .Dictionary:
			let valueType = DictionaryValue(type);
			let valueKind = Classify(valueType, let valueConverter);
			code.AppendF("\t\tTomlBeef.TomlTable _d;\n\t\tif (Try!(TomlBeef.TomlBind.ReadTable(_table, {}, {}, out _d)))\n\t\t{{\n", key, req);
			code.AppendF("\t\t\tif ({0} == null)\n\t\t\t\t{0} = {1};\n\t\t\telse\n\t\t\t{{\n", name, NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
			// The dictionary owns its keys and its object values; with an allocator, the allocator does
			code.AppendF("\t\t\t\tif (_alloc == null)\n\t\t\t\t{{\n\t\t\t\t\tfor (let _old in {})\n\t\t\t\t\t{{\n\t\t\t\t\t\tdelete _old.key;\n", name);
			EmitDeleteValue(code, "_old.value", valueType, valueKind, "\t\t\t\t\t\t");
			code.AppendF("\t\t\t\t\t}}\n\t\t\t\t}}\n\t\t\t\t{}.Clear();\n\t\t\t}}\n", name);
			// Each entry is added first (so the dictionary owns it if reading its value fails), then read
			// in place through the dictionary's ref indexer, by the same code as a field of that type
			StringView initial = (valueKind == .Object && valueType.IsValueType) ? ".()" : "default";
			code.AppendF("\t\t\tfor (int _j < _d.Count)\n\t\t\t{{\n\t\t\t\tlet _dk = _d.GetKeyAt(_j);\n\t\t\t\tlet _dkey = {0};\n\t\t\t\t{1}.Add(_dkey, {2});\n",
				NewExpr("String", "_dk", .. scope .()), name, initial);
			let valueCode = scope String();
			EmitRead(valueCode, scope $"{name}[_dkey]", "_dk", "", true, valueType, valueKind, valueConverter);
			// Read from the dictionary's table: the value code names the table `_table`
			valueCode.Replace("_table", "_d");
			code.Append(valueCode);
			code.Append("\t\t\t}\n\t\t}\n");
		case .Converter:
			code.AppendF("\t\tTomlBeef.TomlValue _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadValue(_table, {0}, {1}, out _v)))\n\t\t\tTry!({2}.Read(_v, .(_table, {0}, _alloc), ref {3}));\n",
				key, req, converter.GetFullName(.. scope .()), name);
		default:
		}
		code.Append("\t}\n");
	}

	/// Appends the deletion of an owned value `expr` of `type` (a dictionary value being replaced): Strings,
	/// class objects and lists are deleted, a list's object items first; value types need nothing.
	[Comptime]
	static void EmitDeleteValue(String code, StringView expr, Type type, Kind kind, StringView indent)
	{
		if (type.IsValueType)
			return;
		if (kind == .List && !ListElement(type).IsValueType)
			code.AppendF("{0}for (let _item in {1})\n{0}\tdelete _item;\n", indent, expr);
		code.AppendF("{}delete {};\n", indent, expr);
	}

	/// An allocation of `typeName(args)` from the read's allocator when there is one, else from the heap.
	[Comptime]
	static void NewExpr(StringView typeName, StringView args, String code)
	{
		code.AppendF("((_alloc != null) ? new:_alloc {0}({1}) : new {0}({1}))", typeName, args);
	}

	/// Appends item `_i` of `_a` to list `name`.
	[Comptime]
	static void EmitReadElement(String code, StringView name, Type type, Kind kind, Type converter)
	{
		StringView indent = "\t\t\t\t";
		switch (kind)
		{
		case .Integer:
			let min = scope String();
			let max = scope String();
			IntegerRange(type, min, max);
			code.AppendF("{}{}.Add((.)Try!(TomlBeef.TomlBind.ElementInteger(_a, _i, {}, {})));\n", indent, name, min, max);
		case .Float:
			code.AppendF("{}{}.Add((.)Try!(TomlBeef.TomlBind.ElementFloat(_a, _i)));\n", indent, name);
		case .Bool:
			code.AppendF("{}{}.Add(Try!(TomlBeef.TomlBind.ElementBool(_a, _i)));\n", indent, name);
		case .String:
			code.AppendF("{0}let _s = Try!(TomlBeef.TomlBind.ElementString(_a, _i));\n{0}{1}.Add({2});\n", indent, name, NewExpr("String", "_s", .. scope .()));
		case .Enum:
			let cases = scope String();
			CaseList(type, cases);
			code.AppendF("{}let _v = Try!(TomlBeef.TomlBind.ElementString(_a, _i));\n", indent);
			let error = scope $"TomlBeef.TomlBind.UnknownCase(_a, _i, _v, \"{cases}\")";
			EmitCaseMatch(code, type, indent, "_v", scope $"{name}.Add(", ")", error);
		case .OffsetDateTime:
			code.AppendF("{}{}.Add(Try!(TomlBeef.TomlBind.ElementOffsetDateTime(_a, _i)));\n", indent, name);
		case .LocalDateTime:
			code.AppendF("{}{}.Add(Try!(TomlBeef.TomlBind.ElementLocalDateTime(_a, _i)));\n", indent, name);
		case .LocalDate:
			code.AppendF("{}{}.Add(Try!(TomlBeef.TomlBind.ElementLocalDate(_a, _i)));\n", indent, name);
		case .LocalTime:
			code.AppendF("{}{}.Add(Try!(TomlBeef.TomlBind.ElementLocalTime(_a, _i)));\n", indent, name);
		case .Object:
			let typeName = type.GetFullName(.. scope .());
			code.AppendF("{}let _t = Try!(TomlBeef.TomlBind.ElementTable(_a, _i));\n", indent);
			if (type.IsValueType)
				code.AppendF("{0}{1} _o = .();\n{0}Try!(_o.TomlRead(_t, _alloc));\n{0}{2}.Add(_o);\n", indent, typeName, name);
			else // added before reading, so the list owns it even if reading fails
				code.AppendF("{0}let _o = {1};\n{0}{2}.Add(_o);\n{0}Try!(_o.TomlRead(_t, _alloc));\n", indent, NewExpr(typeName, "", .. scope .()), name);
		case .Converter:
			// Read in place into a new default item, which the list already owns if reading fails
			code.AppendF("{0}{1}.Add(default);\n{0}Try!({2}.Read(_a.GetValueAt(_i), .(_a, _i, _alloc), ref {1}[{1}.Count - 1]));\n",
				indent, name, converter.GetFullName(.. scope .()));
		default:
		}
	}

	[Comptime]
	static void EmitWrite(String code, StringView name, StringView key, Type type, Kind kind, Type converter)
	{
		switch (kind)
		{
		case .Integer:
			if (type.Size == 8 && !type.IsSigned)
				code.AppendF("\tTry!(TomlBeef.TomlBind.CheckWritable({}, (uint64){}));\n", key, name);
			code.AppendF("\t_table.Set({}, (int64){});\n", key, name);
		case .Float:
			code.AppendF("\t_table.Set({}, (double){});\n", key, name);
		case .Bool, .OffsetDateTime, .LocalDateTime, .LocalDate, .LocalTime:
			code.AppendF("\t_table.Set({}, {});\n", key, name);
		case .String:
			code.AppendF("\tif ({0} != null)\n\t\t_table.Set({1}, (StringView){0});\n\telse\n\t\t_table.Remove({1});\n", name, key);
		case .Enum:
			code.AppendF("\tswitch ({})\n\t{{\n", name);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("\tcase .{}: _table.Set({}, ", field.Name, key);
				AppendLiteral(code, field.Name);
				code.Append(");\n");
			}
			code.Append("\t}\n");
		case .Object:
			// Into the existing table when there is one, so its other keys and comments stay
			if (type.IsValueType)
				code.AppendF("\tTry!({}.TomlWrite(TomlBeef.TomlBind.WriteTable(_table, {})));\n", name, key);
			else
				code.AppendF("\tif ({0} != null)\n\t\tTry!({0}.TomlWrite(TomlBeef.TomlBind.WriteTable(_table, {1})));\n\telse\n\t\t_table.Remove({1});\n", name, key);
		case .List:
			let element = ListElement(type);
			let elementKind = Classify(element, let elementConverter);
			// Items are written by position into the existing array, then any extra items removed. A new
			// list of objects is an array of tables, written as [[key]] sections.
			StringView ofTables = (elementKind == .Object) ? "true" : "false";
			code.AppendF("\tif ({0} != null)\n\t{{\n\t\tlet _a = TomlBeef.TomlBind.WriteArray(_table, {1}, {2});\n\t\tint _i = 0;\n\t\tfor (let _e in {0})\n\t\t{{\n",
				name, key, ofTables);
			EmitWriteElement(code, element, elementKind, elementConverter);
			code.AppendF("\t\t\t_i++;\n\t\t}}\n\t\tTomlBeef.TomlBind.TrimArray(_a, _i);\n\t}}\n\telse\n\t\t_table.Remove({});\n", key);
		case .Dictionary:
			// The dictionary is the whole table: written into the existing one in place (entries that stay
			// keep their position and comments), and keys it no longer has are removed
			let valueType = DictionaryValue(type);
			let valueKind = Classify(valueType, let valueConverter);
			code.AppendF("\tif ({0} != null)\n\t{{\n\t\tlet _d = TomlBeef.TomlBind.WriteTable(_table, {1});\n\t\tTomlBeef.TomlBind.RemoveMissing(_d, {0});\n\t\tfor (let _kv in {0})\n\t\t{{\n",
				name, key);
			let valueCode = scope String();
			EmitWrite(valueCode, "_kv.value", "_kv.key", valueType, valueKind, valueConverter);
			// Write into the dictionary's table: the value code names the table `_table`
			valueCode.Replace("_table", "_d");
			code.Append(valueCode);
			code.AppendF("\t\t}}\n\t}}\n\telse\n\t\t_table.Remove({});\n", key);
		case .Converter:
			code.AppendF("\tTry!({}.Write({}, .(_table, {})));\n", converter.GetFullName(.. scope .()), name, key);
		default:
		}
	}

	/// Writes list item `_e` as item `_i` of array `_a`. A null String or object item is skipped (the
	/// `continue` also skips the caller's `_i++`, so later items close the gap).
	[Comptime]
	static void EmitWriteElement(String code, Type type, Kind kind, Type converter)
	{
		StringView indent = "\t\t\t";
		switch (kind)
		{
		case .Integer:
			if (type.Size == 8 && !type.IsSigned)
				code.AppendF("{}Try!(TomlBeef.TomlBind.CheckWritable(\"[]\", (uint64)_e));\n", indent);
			code.AppendF("{}TomlBeef.TomlBind.WriteItem(_a, _i, (int64)_e);\n", indent);
		case .Float:
			code.AppendF("{}TomlBeef.TomlBind.WriteItem(_a, _i, (double)_e);\n", indent);
		case .Bool, .OffsetDateTime, .LocalDateTime, .LocalDate, .LocalTime:
			code.AppendF("{}TomlBeef.TomlBind.WriteItem(_a, _i, _e);\n", indent);
		case .String:
			code.AppendF("{0}if (_e == null)\n{0}\tcontinue;\n{0}TomlBeef.TomlBind.WriteItem(_a, _i, (StringView)_e);\n", indent);
		case .Enum:
			code.AppendF("{}switch (_e)\n{}{{\n", indent, indent);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case .{}: TomlBeef.TomlBind.WriteItem(_a, _i, ", indent, field.Name);
				AppendLiteral(code, field.Name);
				code.Append(");\n");
			}
			code.AppendF("{}}}\n", indent);
		case .Object:
			if (!type.IsValueType)
				code.AppendF("{0}if (_e == null)\n{0}\tcontinue;\n", indent);
			code.AppendF("{}Try!(_e.TomlWrite(TomlBeef.TomlBind.ItemTable(_a, _i)));\n", indent);
		case .Converter:
			code.AppendF("{}Try!({}.Write(_e, .(_a, _i)));\n", indent, converter.GetFullName(.. scope .()));
		default:
		}
	}
}
