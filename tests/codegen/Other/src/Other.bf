using System;
using TomlBeef;

namespace Other;

/// A second project depending on TomlBeef (see ../BeefSpace.toml): its presence is what made converters
/// registered in Fixtures invisible to the old generator.
[TomlObject]
class OtherThing
{
	public int32 value;
}
