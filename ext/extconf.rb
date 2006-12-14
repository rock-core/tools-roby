require 'mkmf'
CONFIG['CC'] = "g++"
$LDFLAGS += "-module"
pkg_config('utilmm')
create_makefile("bgl")

