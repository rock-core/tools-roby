require 'mkmf'
CONFIG['CC'] = "g++"
dir_config 'boost'
$LDFLAGS += "-module"

_, ldflags, _ = pkg_config 'utilmm'
unless ldflags
    raise 'Util-- not found. It is required to install Roby'
end
$LDFLAGS << ldflags.gsub('-L', ' -Wl,-rpath -Wl,')
create_makefile("bgl")

