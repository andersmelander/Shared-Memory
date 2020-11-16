object FormMain: TFormMain
  Left = 0
  Top = 0
  BorderStyle = bsDialog
  Caption = 'Shared Memory ring buffer test'
  ClientHeight = 145
  ClientWidth = 346
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  Padding.Left = 4
  Padding.Right = 4
  Padding.Bottom = 4
  OldCreateOrder = False
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  PixelsPerInch = 96
  TextHeight = 13
  object LabelStatus: TLabel
    Left = 4
    Top = 128
    Width = 338
    Height = 13
    Align = alBottom
    ExplicitWidth = 3
  end
  object ButtonProduce: TButton
    Left = 24
    Top = 20
    Width = 75
    Height = 25
    Caption = 'Produce'
    TabOrder = 0
    OnClick = ButtonProduceClick
  end
  object ButtonConsume: TButton
    Left = 24
    Top = 51
    Width = 75
    Height = 25
    Caption = 'Consume'
    TabOrder = 1
    OnClick = ButtonConsumeClick
  end
  object ButtonStop: TButton
    Left = 24
    Top = 88
    Width = 75
    Height = 25
    Caption = 'Stop'
    TabOrder = 2
    OnClick = ButtonStopClick
  end
  object TimerUpdate: TTimer
    Enabled = False
    Interval = 100
    OnTimer = TimerUpdateTimer
    Left = 236
    Top = 8
  end
end
