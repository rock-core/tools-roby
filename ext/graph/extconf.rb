require 'mkmf'
CONFIG['CC'] = "g++"
dir_config 'boost'
$LDFLAGS += "-module"

create_makefile("bgl")

