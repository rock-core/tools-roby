# frozen_string_literal: true

require "pathname"

# This is needed because of Ruby bug #9244
module Syskit
    module CustomRequire #:nodoc:
        def self.resolve(path)
            match = /^([\w|-]+)\//.match(path)
            return path unless match

            prefix = match[1]
            if (full_path = resolve_from_apps(prefix, path))
                return full_path
            end

            if (full_path = resolve_from_search_path(path))
                return full_path
            end

            path
        end

        def self.resolve_from_apps(prefix, path)
            app_base_dir = Roby.app.find_registered_app_path(prefix)
            return unless app_base_dir

            full_path = File.join(File.dirname(app_base_dir), path)
            return unless File.file?(full_path) || File.file?("#{full_path}.rb")

            full_path
        end

        def self.resolve_from_search_path(path)
            Roby.app.search_path.find do |dir|
                full_path = File.join(dir, path)
                return full_path if File.file?(full_path) || File.file?("#{full_path}.rb")
            end
        end
    end
end

module Kernel #:nodoc:
    alias syskit_original_require require
    def require(path)
        # Only deal with paths which is not prefixed with an app_dir basename,
        # the other ones are unambiguous
        resolved_path = Syskit::CustomRequire.resolve(path)

        syskit_original_require(resolved_path)
    end
end
