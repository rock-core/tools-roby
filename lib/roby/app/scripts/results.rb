require File.join(File.dirname(__FILE__), '..', 'run')
require File.join(File.dirname(__FILE__), '..', 'load')
Roby.app.setup
app = Roby.app

# Check there are actually files in the log/ directory
if Dir.enum_for(:glob, File.join(app.log_dir, "*")).to_a.empty?
    puts "no files in #{app.log_dir}, nothing to do"
    exit 0
end

user_base_path = ARGV.shift
if user_base_path =~ /\/$/
    basename = ""
    dirname = user_base_path
else
    basename = File.basename(user_base_path)
    dirname  = File.dirname(user_base_path)
end

date = Date.today
date = "%i%02i%02i" % [date.year, date.month, date.mday]
if basename && !basename.empty?
    basename = date + "-" + basename
else
    basename = date
end

# Check if +basename+ already exists, and if it is the case add a
# .x suffix to it
full_path = File.expand_path(File.join(dirname, basename), app.results_dir)
base_dir  = File.dirname(full_path)

unless File.exists?(base_dir)
    FileUtils.mkdir_p(base_dir)
end

final_path, i = full_path, 0
while File.exists?(final_path)
    i += 1
    final_path = full_path + ".#{i}"
end

puts "moving #{app.log_dir} to #{final_path}"
FileUtils.mv app.log_dir, final_path
