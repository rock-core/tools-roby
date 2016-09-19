require 'roby/test/self'
require 'roby/test/roby_app_helpers'
require 'roby/app/installer'

module Roby
    describe Installer do
        include Roby::Test::RobyAppHelpers

        it "creates a valid Roby application" do
            dir = make_tmpdir
            capture_subprocess_io do
                assert system(roby_bin, 'init', chdir: dir)
                pid = roby_app_spawn 'run', chdir: dir
                assert_roby_app_quits(pid)
            end
        end
    end
end

