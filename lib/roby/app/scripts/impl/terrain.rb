require File.join(APP_DIR, 'config', 'init')
require 'roby/adapters/genom'
require File.join(ROBY_DIR, 'config', 'adapters', 'genom')
require 'genom'

Tempfile.open('terrain_disply') do |io|
    io.puts <<-EOF
name: terrain_display
bridge: gazebo

gazebo
{
    world: #{File.join(APP_DIR, "data", TERRAIN['gazebo'])}
    server-id: 1
}
    EOF
    io.flush

    Genom::Runner.gazebo io.path do |gzb|
	gdhe_display(gzb, ARGV[0]) do
	    gzb.join
	end
    end
end

