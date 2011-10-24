require 'roby'
ARGV << "--config=#{File.join(Roby.app.app_dir, "config", "roby-display.yml")}"
load File.join(File.expand_path(File.join('..', '..', '..', '..', 'bin', 'roby-display'), File.dirname(__FILE__)))
