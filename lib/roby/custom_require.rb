# frozen_string_literal: true

# This is needed because of Ruby bug #9244
module Kernel
    alias syskit_original_require require
    def require(path)
        # Only deal with paths starting with models/, the other ones are
        # unambiguous
        if path =~ /^models\//
            Roby.app.search_path.each do |app_dir|
                full_path = File.join(app_dir, path)
                if File.file?(full_path) || File.file?("#{full_path}.rb")
                    return syskit_original_require(full_path)
                end
            end
        elsif (match = /^(\w+)\/models\//.match(path))
            app_name = match[1]
            if (base_dir = Roby.app.find_registered_app_path(app_name))
                full_path = File.join(File.dirname(base_dir), path)
                if File.file?(full_path) || File.file?("#{full_path}.rb")
                    return syskit_original_require(full_path)
                end
            end
        end
        syskit_original_require(path)
    end
end
