require 'roby'
if !(config_file = Roby.app.find_files('config', 'roby-display.yml', :all => false, :order => :specific_first))
    config_file = File.join(Roby.app.app_dir, "config", "roby-display.yml")
end
ARGV << "--config=#{config_file}"
load File.join(File.expand_path(File.join('..', '..', '..', '..', 'bin', 'roby-display'), File.dirname(__FILE__)))
