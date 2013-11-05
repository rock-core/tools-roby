require 'roby'

app = Roby.app
app.require_app_dir
app.public_shell_interface = true
app.public_logs = true

options = OptionParser.new do |opt|
    opt.banner = <<-EOD
roby test [-r ROBOT] FILES
    EOD

    Roby::Application.common_optparse_setup(opt)
end
remaining_arguments = options.parse(ARGV)

direct_files, actions = remaining_arguments.partition do |arg|
    File.file?(arg)
end
Roby.app.additional_model_files.concat(direct_files)

Roby.display_exception do
    app.setup

    remaining_arguments.each do |file|
        require File.expand_path(file)
    end
    MiniTest::Unit.new.run
end

