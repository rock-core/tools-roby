<% indent, open_code, close_code = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open_code %>
<%= indent %>class <%= class_name.last %>
<%= indent %>end
<%= close_code %>
