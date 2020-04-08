# frozen_string_literal: true

require "roby"
if defined? APP_DIR
    Dir.chdir(APP_DIR)
end
Roby.app.base_setup
