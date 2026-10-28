=begin
** Form generated from reading ui file 'relations_view.ui'
**
** Created: qua out 28 14:09:58 2026
**      by: Qt User Interface Compiler version 4.8.7
**
** WARNING! All changes made in this file will be lost when recompiling ui file!
=end

class Ui_RelationsView
    attr_reader :verticalLayout
    attr_reader :splitter
    attr_reader :graphics
    attr_reader :scheduler_view_holder

    def setupUi(relationsView)
    if relationsView.objectName.nil?
        relationsView.objectName = "relationsView"
    end
    relationsView.resize(948, 683)
    @verticalLayout = Qt::VBoxLayout.new(relationsView)
    @verticalLayout.objectName = "verticalLayout"
    @splitter = Qt::Splitter.new(relationsView)
    @splitter.objectName = "splitter"
    @splitter.orientation = Qt::Vertical
    @graphics = Qt::GraphicsView.new(@splitter)
    @graphics.objectName = "graphics"
    @sizePolicy = Qt::SizePolicy.new(Qt::SizePolicy::Expanding, Qt::SizePolicy::Expanding)
    @sizePolicy.setHorizontalStretch(10)
    @sizePolicy.setVerticalStretch(0)
    @sizePolicy.heightForWidth = @graphics.sizePolicy.hasHeightForWidth
    @graphics.sizePolicy = @sizePolicy
    @graphics.minimumSize = Qt::Size.new(250, 250)
    @graphics.renderHints = Qt::Painter::Antialiasing|Qt::Painter::TextAntialiasing
    @splitter.addWidget(@graphics)
    @scheduler_view_holder = Qt::Widget.new(@splitter)
    @scheduler_view_holder.objectName = "scheduler_view_holder"
    @scheduler_view_holder.minimumSize = Qt::Size.new(0, 100)
    @splitter.addWidget(@scheduler_view_holder)

    @verticalLayout.addWidget(@splitter)


    retranslateUi(relationsView)

    Qt::MetaObject.connectSlotsByName(relationsView)
    end # setupUi

    def setup_ui(relationsView)
        setupUi(relationsView)
    end

    def retranslateUi(relationsView)
    relationsView.windowTitle = Qt::Application.translate("RelationsView", "Roby Display", nil, Qt::Application::UnicodeUTF8)
    end # retranslateUi

    def retranslate_ui(relationsView)
        retranslateUi(relationsView)
    end

end

module Ui
    class RelationsView < Ui_RelationsView
    end
end  # module Ui

