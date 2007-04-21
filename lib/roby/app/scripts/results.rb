require File.join(File.dirname(__FILE__), '..', 'run')
require File.join(File.dirname(__FILE__), '..', 'load')
Roby.app.setup
app = Roby.app

# Check there are actually files in the log/ directory
if Dir.enum_for(:glob, File.join(app.log_dir, "*")).to_a.empty?
    puts "no files in #{app.log_dir}, nothing to do"
    exit 0
end

basename = ARGV.shift
date = Date.today
date = "%i%02i%02i" % [date.year, date.month, date.mday]
if basename && !basename.empty?
    basename = date + "-" + basename
else
    basename = date
end

# Check if +basename+ already exists, and if it is the case add a
# .x suffix to it
basename = File.join(app.results_dir, basename)
dirname, i = basename, 0
while File.exists?(dirname)
    i += 1
    dirname = basename + ".#{i}"
end

if !File.directory?(app.results_dir)
    Dir.mkdir(app.results_dir)
end

puts "moving #{app.log_dir} to #{dirname}"
FileUtils.mv app.log_dir, dirname
