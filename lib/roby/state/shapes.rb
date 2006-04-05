
Dir.glob( File.join(File.dirname(__FILE__), 'shapes', '**', '*.rb') ) do |file|
    require file
end

