SimpleCov.command_name 'roby'
SimpleCov.start do
    add_filter "/test/"
    add_filter "/gui/"
    add_filter "/scripts/"
end

require 'roby'

