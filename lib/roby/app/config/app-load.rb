require 'roby/app/config'
require 'roby/app/tools'

require 'yaml'
require 'fileutils'
require 'tempfile'

$LOAD_PATH.unshift APP_DIR

# We expect here that both APP_DIR and ROBOT are set
conf = Roby::Application.config
file = File.join(APP_DIR, 'config', 'roby.yml')
file = YAML.load(File.open(file))

conf.load(file)

# Get the application-wide configuration
require File.join(APP_DIR, 'config', 'init')

