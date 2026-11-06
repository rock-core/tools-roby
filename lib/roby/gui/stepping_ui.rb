=begin
** Form generated from reading ui file 'stepping.ui'
**
** Created: qua out 28 14:09:58 2026
**      by: Qt User Interface Compiler version 4.8.7
**
** WARNING! All changes made in this file will be lost when recompiling ui file!
=end

class Ui_Stepping
    attr_reader :gridLayout
    attr_reader :btn_next
    attr_reader :lbl_index
    attr_reader :index
    attr_reader :index_count
    attr_reader :lbl_cycle
    attr_reader :cycle
    attr_reader :cycle_count
    attr_reader :lbl_time
    attr_reader :time

    def setupUi(stepping)
    if stepping.objectName.nil?
        stepping.objectName = "stepping"
    end
    stepping.windowModality = Qt::WindowModal
    stepping.resize(356, 78)
    @sizePolicy = Qt::SizePolicy.new(Qt::SizePolicy::Expanding, Qt::SizePolicy::Expanding)
    @sizePolicy.setHorizontalStretch(0)
    @sizePolicy.setVerticalStretch(0)
    @sizePolicy.heightForWidth = stepping.sizePolicy.hasHeightForWidth
    stepping.sizePolicy = @sizePolicy
    stepping.minimumSize = Qt::Size.new(356, 0)
    @gridLayout = Qt::GridLayout.new(stepping)
    @gridLayout.objectName = "gridLayout"
    @btn_next = Qt::PushButton.new(stepping)
    @btn_next.objectName = "btn_next"
    @sizePolicy1 = Qt::SizePolicy.new(Qt::SizePolicy::Maximum, Qt::SizePolicy::Maximum)
    @sizePolicy1.setHorizontalStretch(0)
    @sizePolicy1.setVerticalStretch(0)
    @sizePolicy1.heightForWidth = @btn_next.sizePolicy.hasHeightForWidth
    @btn_next.sizePolicy = @sizePolicy1
    @btn_next.minimumSize = Qt::Size.new(60, 60)
    @btn_next.maximumSize = Qt::Size.new(70, 70)
    @btn_next.focusPolicy = Qt::StrongFocus
    icon = Qt::Icon.new
    icon.addPixmap(Qt::Pixmap.new("next.png"), Qt::Icon::Normal, Qt::Icon::Off)
    @btn_next.icon = icon
    @btn_next.iconSize = Qt::Size.new(40, 40)

    @gridLayout.addWidget(@btn_next, 0, 0, 3, 1)

    @lbl_index = Qt::Label.new(stepping)
    @lbl_index.objectName = "lbl_index"
    @font = Qt::Font.new
    @font.pointSize = 8
    @lbl_index.font = @font

    @gridLayout.addWidget(@lbl_index, 0, 1, 1, 1)

    @index = Qt::Label.new(stepping)
    @index.objectName = "index"

    @gridLayout.addWidget(@index, 0, 2, 1, 1)

    @index_count = Qt::Label.new(stepping)
    @index_count.objectName = "index_count"

    @gridLayout.addWidget(@index_count, 0, 3, 1, 1)

    @lbl_cycle = Qt::Label.new(stepping)
    @lbl_cycle.objectName = "lbl_cycle"
    @lbl_cycle.font = @font

    @gridLayout.addWidget(@lbl_cycle, 1, 1, 1, 1)

    @cycle = Qt::Label.new(stepping)
    @cycle.objectName = "cycle"

    @gridLayout.addWidget(@cycle, 1, 2, 1, 1)

    @cycle_count = Qt::Label.new(stepping)
    @cycle_count.objectName = "cycle_count"

    @gridLayout.addWidget(@cycle_count, 1, 3, 1, 1)

    @lbl_time = Qt::Label.new(stepping)
    @lbl_time.objectName = "lbl_time"
    @lbl_time.font = @font

    @gridLayout.addWidget(@lbl_time, 2, 1, 1, 1)

    @time = Qt::Label.new(stepping)
    @time.objectName = "time"
    @time.maximumSize = Qt::Size.new(252, 250)
    @font1 = Qt::Font.new
    @font1.family = "Times New Roman"
    @font1.pointSize = 8
    @time.font = @font1
    @time.frameShape = Qt::Frame::Box
    @time.lineWidth = 1

    @gridLayout.addWidget(@time, 2, 2, 1, 2)


    retranslateUi(stepping)

    Qt::MetaObject.connectSlotsByName(stepping)
    end # setupUi

    def setup_ui(stepping)
        setupUi(stepping)
    end

    def retranslateUi(stepping)
    stepping.windowTitle = Qt::Application.translate("Stepping", "Stepping", nil, Qt::Application::UnicodeUTF8)
    @btn_next.text = ''
    @lbl_index.text = Qt::Application.translate("Stepping", "Index", nil, Qt::Application::UnicodeUTF8)
    @index.text = Qt::Application.translate("Stepping", "0", nil, Qt::Application::UnicodeUTF8)
    @index_count.text = Qt::Application.translate("Stepping", "/0", nil, Qt::Application::UnicodeUTF8)
    @lbl_cycle.text = Qt::Application.translate("Stepping", "Cycle", nil, Qt::Application::UnicodeUTF8)
    @cycle.text = Qt::Application.translate("Stepping", "0", nil, Qt::Application::UnicodeUTF8)
    @cycle_count.text = Qt::Application.translate("Stepping", "/0", nil, Qt::Application::UnicodeUTF8)
    @lbl_time.text = Qt::Application.translate("Stepping", "Time:", nil, Qt::Application::UnicodeUTF8)
    @time.text = ''
    end # retranslateUi

    def retranslate_ui(stepping)
        retranslateUi(stepping)
    end

end

module Ui
    class Stepping < Ui_Stepping
    end
end  # module Ui

