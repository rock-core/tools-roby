require 'roby'
require 'fileutils'
Roby.app.load_base_config
app = Roby.app

# Check there are actually files in the log/ directory
if app.log_dir_empty?
    puts "no files in #{app.log_dir}, nothing to do"
    exit 0
end

Roby.app.log_save(app.results_dir, ARGV.shift)

