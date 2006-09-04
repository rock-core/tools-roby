require 'mkmf'
CONFIG['CC'] = "g++"
$LDFLAGS += "-module"
create_makefile("faster")

