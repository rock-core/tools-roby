require 'roby/app'

require 'yaml'
require 'fileutils'
require 'tempfile'

$LOAD_PATH.unshift APP_DIR

# We expect here that both APP_DIR and ROBOT are set
conf = Roby.app
file = File.join(APP_DIR, 'config', 'app.yml')
file = YAML.load(File.open(file))

conf.load(file)

# Get the application-wide configuration
if File.exists?(initfile = File.join(APP_DIR, 'config', 'init.rb'))
    load initfile
end

