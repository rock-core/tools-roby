require 'mkmf'
CONFIG['CC'] = "g++"
dir_config 'boost'
$LDFLAGS += "-module"
_, ldflags, _ = pkg_config 'utilmm'
$LDFLAGS << ldflags.gsub('-L', ' -Wl,-rpath -Wl,')
create_makefile("bgl")

