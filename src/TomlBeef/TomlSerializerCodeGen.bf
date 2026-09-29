using System;
using System.Collections;
using System.Reflection;

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
		/// An ITomlConverter<T>: from [TomlUseConverter] on the field, or registered with [TomlConverter]
		Converter
	}

	/// @brief Emit ITomlSerializable, TomlRead and TomlWrite into `type`.
	/// @param type A class or struct carrying [TomlObject].
	/// @param naming How field names (and the type name, for the key) become keys.
	/// @param homeKey The type's table in a document (TomlObjectAttribute.Key), or empty for its name.
	[Comptime]
	public static void Emit(Type type, TomlKeyNaming naming, StringView homeKey)
	{
		let read = scope String();
		let write = scope String();

		// A [TomlObject] base already has both methods: hide them, and read and write its fields first
		bool baseIsObject = type.BaseType != null && type.BaseType != typeof(Object) && type.BaseType.HasCustomAttribute<TomlObjectAttribute>();
		StringView hide = baseIsObject ? "new " : "";

		// Where path-less TomlDocument.Deserialize/Serialize find the type: its Key, or its own name
		let home = scope String();
		if (!homeKey.IsEmpty)
			home.Append(homeKey);
		else
			ApplyNaming(type.GetName(.. scope .()), naming, home);
		let homeLiteral = AppendLiteral(.. scope .(), home);
		read.AppendF("public {}static StringView TomlKey => {};\n", hide, homeLiteral);
		read.AppendF("public {}Result<void, TomlBeef.TomlParseError> TomlRead(TomlBeef.TomlTable _table, System.ITypedAllocator _alloc = null){}\n{{\n", hide, type.IsValueType ? " mut" : "");
		write.AppendF("public {}Result<void, TomlBeef.TomlParseError> TomlWrite(TomlBeef.TomlTable _table)\n{{\n", hide);
		if (baseIsObject)
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
			var elementKind = Kind.Bool;
			if (kind == .List)
				elementKind = Classify(ListElement(fieldType), ?);
			// Lists of lists are left for later
			if (kind == .Unsupported || elementKind == .Unsupported || elementKind == .List)
			{
				let typeName = fieldType.GetFullName(.. scope .());
				let ownerName = type.GetFullName(.. scope .());
				Runtime.FatalError(scope $"[TomlObject] {ownerName}.{field.Name}: TOML serialization does not support fields of type {typeName}. Supported: bool, integers, float, double, String, enums, the TOML date/time types, [TomlObject] types, List<T> of those, and types with a converter ([TomlConverter] registration or [TomlUseConverter] on the field). Mark the field [TomlIgnore] to leave it out.");
			}

			EmitRead(read, field.Name, key, required, fieldType, kind, converter);
			EmitWrite(write, field.Name, key, fieldType, kind, converter);
		}

		read.Append("\treturn .Ok;\n}\n");
		write.Append("\treturn .Ok;\n}\n");

		Compiler.EmitAddInterface(type, typeof(ITomlSerializable));
		Compiler.EmitTypeBody(type, read);
		Compiler.EmitTypeBody(type, write);
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
		return .Unsupported;
	}

	/// The converter registered with [TomlConverter(typeof(target))] that the type being compiled can see
	/// (declared in its project or a dependency), or null. Two such registrations stop the build.
	[Comptime]
	static Type FindRegisteredConverter(Type target)
	{
		Type found = null;
		for (let declaration in Type.TypeDeclarations)
		{
			if (!(declaration.DeclaredInCurrent || declaration.DeclaredInDependency || declaration.AlwaysVisible))
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
	static Type ListElement(Type type)
	{
		if (let specialized = type as SpecializedGenericType)
		{
			if (specialized.UnspecializedType == typeof(List<>))
				return specialized.GetGenericArg(0);
		}
		return null;
	}

	/// Appends the key for field `name`. Words start at an upper-case letter that follows a lower-case
	/// letter or digit, or that ends an acronym (the last capital before a lower-case letter), so
	/// `HTTPPort` splits as HTTP, Port and `Utf8Name` as Utf8, Name; underscores also split.
	[Comptime]
	static void ApplyNaming(StringView name, TomlKeyNaming naming, String key)
	{
		if (naming == .AsDeclared)
		{
			key.Append(name);
			return;
		}
		int words = 0;
		int i = 0;
		while (i < name.Length)
		{
			if (name[i] == '_')
			{
				i++;
				continue;
			}
			// One word: up to the next underscore or word-starting capital
			int start = i++;
			while (i < name.Length && name[i] != '_' && !(name[i].IsUpper && (name[i - 1].IsLower || name[i - 1].IsDigit ||
				(name[i - 1].IsUpper && i + 1 < name.Length && name[i + 1].IsLower))))
				i++;

			if (words > 0 && naming != .CamelCase)
				key.Append(naming == .KebabCase ? '-' : '_');
			for (int j = start; j < i; j++)
				key.Append((naming == .CamelCase && words > 0 && j == start) ? name[j].ToUpper : name[j].ToLower);
			words++;
		}
	}

	/// Appends `text` as a Beef string literal. Keys are ordinary text; control characters, which a
	/// field name cannot hold and a TomlName has no reason to, stop the build.
	[Comptime]
	static void AppendLiteral(String code, StringView text)
	{
		code.Append('"');
		for (let c in text.RawChars)
		{
			switch (c)
			{
			case '"': code.Append("\\\"");
			case '\\': code.Append("\\\\");
			default:
				if ((uint8)c < 0x20)
					Runtime.FatalError(scope $"[TomlName] \"{text}\" contains a control character");
				code.Append(c);
			}
		}
		code.Append('"');
	}

	/// The smallest and largest value of an integer type, as int64 source expressions. TOML integers are
	/// int64, so 64-bit unsigned types read up to int64.MaxValue.
	[Comptime]
	static void IntegerRange(Type type, String min, String max)
	{
		int bits = type.Size * 8;
		if (bits == 64)
		{
			min.Append(type.IsSigned ? "int64.MinValue" : "0");
			max.Append("int64.MaxValue");
		}
		else if (type.IsSigned)
		{
			min.AppendF("{}", -(1L << (bits - 1)));
			max.AppendF("{}", (1L << (bits - 1)) - 1);
		}
		else
		{
			min.Append("0");
			max.AppendF("{}", (1L << bits) - 1);
		}
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

	[Comptime]
	static void EmitRead(String code, StringView name, StringView key, bool required, Type type, Kind kind, Type converter)
	{
		StringView req = required ? "true" : "false";
		code.Append("\t{\n");
		switch (kind)
		{
		case .Integer:
			let min = scope String();
			let max = scope String();
			IntegerRange(type, min, max);
			code.AppendF("\t\tint64 _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadInteger(_table, {}, {}, {}, {}, out _v)))\n\t\t\tthis.{} = (.)_v;\n", key, req, min, max, name);
		case .Float:
			code.AppendF("\t\tdouble _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadFloat(_table, {}, {}, out _v)))\n\t\t\tthis.{} = (.)_v;\n", key, req, name);
		case .Bool:
			code.AppendF("\t\tbool _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadBool(_table, {}, {}, out _v)))\n\t\t\tthis.{} = _v;\n", key, req, name);
		case .String:
			code.AppendF("\t\tStringView _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadString(_table, {}, {}, out _v)))\n\t\t{{\n", key, req);
			code.AppendF("\t\t\tif (this.{0} == null)\n\t\t\t\tthis.{0} = {1};\n\t\t\telse\n\t\t\t\tthis.{0}.Set(_v);\n\t\t}}\n", name, NewExpr("String", "_v", .. scope .()));
		case .Enum:
			let cases = scope String();
			CaseList(type, cases);
			code.AppendF("\t\tStringView _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadString(_table, {}, {}, out _v)))\n", key, req);
			let error = scope $"TomlBeef.TomlBind.UnknownCase(_table, {key}, _v, \"{cases}\")";
			EmitCaseMatch(code, type, "\t\t", "_v", scope $"this.{name} = ", "", error);
		case .OffsetDateTime, .LocalDateTime, .LocalDate, .LocalTime:
			code.AppendF("\t\tTry!(TomlBeef.TomlBind.ReadDateTime(_table, {}, {}, ref this.{}));\n", key, req, name);
		case .Object:
			code.AppendF("\t\tTomlBeef.TomlTable _t;\n\t\tif (Try!(TomlBeef.TomlBind.ReadTable(_table, {}, {}, out _t)))\n\t\t{{\n", key, req);
			if (!type.IsValueType)
				code.AppendF("\t\t\tif (this.{0} == null)\n\t\t\t\tthis.{0} = {1};\n", name, NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
			code.AppendF("\t\t\tTry!(this.{}.TomlRead(_t, _alloc));\n\t\t}}\n", name);
		case .List:
			let element = ListElement(type);
			let elementKind = Classify(element, let elementConverter);
			code.AppendF("\t\tTomlBeef.TomlArray _a;\n\t\tif (Try!(TomlBeef.TomlBind.ReadArray(_table, {}, {}, out _a)))\n\t\t{{\n", key, req);
			code.AppendF("\t\t\tif (this.{0} == null)\n\t\t\t\tthis.{0} = {1};\n", name, NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
			// Without an allocator the list owns its object items (Strings, objects, converted classes):
			// delete them before replacing. With one, the allocator owns what reads create.
			if (!element.IsValueType)
				code.AppendF("\t\t\tif (_alloc == null)\n\t\t\t{{\n\t\t\t\tfor (let _old in this.{})\n\t\t\t\t\tdelete _old;\n\t\t\t}}\n", name);
			code.AppendF("\t\t\tthis.{}.Clear();\n\t\t\tfor (int _i < _a.Count)\n\t\t\t{{\n", name);
			EmitReadElement(code, name, element, elementKind, elementConverter);
			code.Append("\t\t\t}\n\t\t}\n");
		case .Converter:
			code.AppendF("\t\tTomlBeef.TomlValue _v;\n\t\tif (Try!(TomlBeef.TomlBind.ReadValue(_table, {0}, {1}, out _v)))\n\t\t\tTry!({2}.Read(_v, .(_table, {0}, _alloc), ref this.{3}));\n",
				key, req, converter.GetFullName(.. scope .()), name);
		default:
		}
		code.Append("\t}\n");
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
			code.AppendF("{}this.{}.Add((.)Try!(TomlBeef.TomlBind.ElementInteger(_a, _i, {}, {})));\n", indent, name, min, max);
		case .Float:
			code.AppendF("{}this.{}.Add((.)Try!(TomlBeef.TomlBind.ElementFloat(_a, _i)));\n", indent, name);
		case .Bool:
			code.AppendF("{}this.{}.Add(Try!(TomlBeef.TomlBind.ElementBool(_a, _i)));\n", indent, name);
		case .String:
			code.AppendF("{0}let _s = Try!(TomlBeef.TomlBind.ElementString(_a, _i));\n{0}this.{1}.Add({2});\n", indent, name, NewExpr("String", "_s", .. scope .()));
		case .Enum:
			let cases = scope String();
			CaseList(type, cases);
			code.AppendF("{}let _v = Try!(TomlBeef.TomlBind.ElementString(_a, _i));\n", indent);
			let error = scope $"TomlBeef.TomlBind.UnknownCase(_a, _i, _v, \"{cases}\")";
			EmitCaseMatch(code, type, indent, "_v", scope $"this.{name}.Add(", ")", error);
		case .OffsetDateTime:
			code.AppendF("{}this.{}.Add(Try!(TomlBeef.TomlBind.ElementOffsetDateTime(_a, _i)));\n", indent, name);
		case .LocalDateTime:
			code.AppendF("{}this.{}.Add(Try!(TomlBeef.TomlBind.ElementLocalDateTime(_a, _i)));\n", indent, name);
		case .LocalDate:
			code.AppendF("{}this.{}.Add(Try!(TomlBeef.TomlBind.ElementLocalDate(_a, _i)));\n", indent, name);
		case .LocalTime:
			code.AppendF("{}this.{}.Add(Try!(TomlBeef.TomlBind.ElementLocalTime(_a, _i)));\n", indent, name);
		case .Object:
			let typeName = type.GetFullName(.. scope .());
			code.AppendF("{}let _t = Try!(TomlBeef.TomlBind.ElementTable(_a, _i));\n", indent);
			if (type.IsValueType)
				code.AppendF("{0}{1} _o = .();\n{0}Try!(_o.TomlRead(_t, _alloc));\n{0}this.{2}.Add(_o);\n", indent, typeName, name);
			else // added before reading, so the list owns it even if reading fails
				code.AppendF("{0}let _o = {1};\n{0}this.{2}.Add(_o);\n{0}Try!(_o.TomlRead(_t, _alloc));\n", indent, NewExpr(typeName, "", .. scope .()), name);
		case .Converter:
			// Read in place into a new default item, which the list already owns if reading fails
			code.AppendF("{0}this.{1}.Add(default);\n{0}Try!({2}.Read(_a.GetValueAt(_i), .(_a, _i, _alloc), ref this.{1}[this.{1}.Count - 1]));\n",
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
				code.AppendF("\tTry!(TomlBeef.TomlBind.CheckWritable({}, (uint64)this.{}));\n", key, name);
			code.AppendF("\t_table.Set({}, (int64)this.{});\n", key, name);
		case .Float:
			code.AppendF("\t_table.Set({}, (double)this.{});\n", key, name);
		case .Bool, .OffsetDateTime, .LocalDateTime, .LocalDate, .LocalTime:
			code.AppendF("\t_table.Set({}, this.{});\n", key, name);
		case .String:
			code.AppendF("\tif (this.{0} != null)\n\t\t_table.Set({1}, (StringView)this.{0});\n\telse\n\t\t_table.Remove({1});\n", name, key);
		case .Enum:
			code.AppendF("\tswitch (this.{})\n\t{{\n", name);
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
				code.AppendF("\tTry!(this.{}.TomlWrite(TomlBeef.TomlBind.WriteTable(_table, {})));\n", name, key);
			else
				code.AppendF("\tif (this.{0} != null)\n\t\tTry!(this.{0}.TomlWrite(TomlBeef.TomlBind.WriteTable(_table, {1})));\n\telse\n\t\t_table.Remove({1});\n", name, key);
		case .List:
			let element = ListElement(type);
			let elementKind = Classify(element, let elementConverter);
			// Items are written by position into the existing array, then any extra items removed. A new
			// list of objects is an array of tables, written as [[key]] sections.
			StringView ofTables = (elementKind == .Object) ? "true" : "false";
			code.AppendF("\tif (this.{0} != null)\n\t{{\n\t\tlet _a = TomlBeef.TomlBind.WriteArray(_table, {1}, {2});\n\t\tint _i = 0;\n\t\tfor (let _e in this.{0})\n\t\t{{\n",
				name, key, ofTables);
			EmitWriteElement(code, element, elementKind, elementConverter);
			code.AppendF("\t\t\t_i++;\n\t\t}}\n\t\tTomlBeef.TomlBind.TrimArray(_a, _i);\n\t}}\n\telse\n\t\t_table.Remove({});\n", key);
		case .Converter:
			code.AppendF("\tTry!({}.Write(this.{}, .(_table, {})));\n", converter.GetFullName(.. scope .()), name, key);
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
