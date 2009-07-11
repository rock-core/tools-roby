require 'roby'
require 'fileutils'
Roby.app.setup
app = Roby.app

# Check there are actually files in the log/ directory
if Dir.enum_for(:glob, File.join(app.log_dir, "*")).to_a.empty?
    puts "no files in #{app.log_dir}, nothing to do"
    exit 0
end

user_path = ARGV.shift || ''
final_path = Roby::Application.unique_dirname(Roby.app.results_dir, user_path)
puts "moving #{app.log_dir} to #{final_path}"
FileUtils.mv app.log_dir, final_path

