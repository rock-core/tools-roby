require 'rake/rdoctask'

Rake::RDocTask.new('doc') do |doc|
    doc.rdoc_files.include 'README.txt'
    doc.rdoc_files.include 'tasks/**/*.rb'
    doc.rdoc_files.include 'planners/**/*.rb'
    doc.rdoc_files.include 'controllers/**/*.rb'
end
task 'default' => 'doc'
