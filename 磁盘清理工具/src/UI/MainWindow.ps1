Add-Type -AssemblyName PresentationFramework

$mod = Join-Path $PSScriptRoot '..\Modules'
'Analyzer','DiskScanner','TempCleaner','BrowserCache','RecycleBin','LargeFiles','LargeFolders','SystemJunk','Remover' |
    ForEach-Object { Import-Module (Join-Path $mod "$_.psm1") -Force }

# 小工具：把 #RRGGBB 颜色字符串转成画刷
function B([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="磁盘清理工具" Height="720" Width="900" MinWidth="720" MinHeight="560"
        WindowStartupLocation="CenterScreen" Background="#F0F2F5" FontFamily="Microsoft YaHei">
  <Window.Resources>
    <!-- 主按钮：圆角、悬停变深、禁用变灰 -->
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="18,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.88"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#9CA3AF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 分类筛选「胶囊」按钮：选中变蓝 -->
    <Style x:Key="Chip" TargetType="ToggleButton">
      <Setter Property="Margin" Value="0,0,10,6"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="bd" CornerRadius="18" Background="White" BorderBrush="#D1D5DB" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2563EB"/>
                <Setter TargetName="bd" Property="BorderBrush" Value="#2563EB"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 卡片容器 -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Effect">
        <Setter.Value>
          <DropShadowEffect BlurRadius="14" ShadowDepth="1.5" Direction="270" Color="#1F2933" Opacity="0.07"/>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 标题 -->
    <StackPanel Grid.Row="0" Margin="2,0,0,16">
      <TextBlock Text="🧹 磁盘清理工具" FontSize="22" FontWeight="Bold" Foreground="#111827"/>
      <TextBlock Text="选磁盘、勾内容、点开始扫描；扫描在后台跑，界面不会卡，随时可取消。鼠标移到某一行可看详细说明，右键可打开文件所在位置。"
                 FontSize="12" Foreground="#6B7280" Margin="0,6,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <!-- 磁盘卡片 -->
    <WrapPanel Grid.Row="1" x:Name="DiskPanel" Margin="0,0,0,12"/>

    <!-- 分类筛选 + 扫描按钮（窄窗口时胶囊自动换行，按钮始终在右） -->
    <Grid Grid.Row="2" Margin="0,0,0,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <WrapPanel Grid.Column="0" VerticalAlignment="Center">
        <ToggleButton x:Name="CbTemp"      Style="{StaticResource Chip}" Content="🧽 系统临时" IsChecked="True"/>
        <ToggleButton x:Name="CbRecycle"   Style="{StaticResource Chip}" Content="🗑 回收站" IsChecked="True"/>
        <ToggleButton x:Name="CbBrowser"   Style="{StaticResource Chip}" Content="🌐 浏览器缓存" IsChecked="True"/>
        <ToggleButton x:Name="CbWinUpdate" Style="{StaticResource Chip}" Content="♻️ 更新缓存" IsChecked="True"/>
        <ToggleButton x:Name="CbCrash"     Style="{StaticResource Chip}" Content="💥 崩溃转储" IsChecked="True"/>
        <ToggleButton x:Name="CbThumb"     Style="{StaticResource Chip}" Content="🖼️ 缩略图缓存" IsChecked="True"/>
        <ToggleButton x:Name="CbLog"       Style="{StaticResource Chip}" Content="📜 系统日志" IsChecked="True"/>
        <ToggleButton x:Name="CbLarge"     Style="{StaticResource Chip}" Content="📦 大文件 &gt;100MB" IsChecked="True"/>
        <ToggleButton x:Name="CbLargeFolder" Style="{StaticResource Chip}" Content="🗂️ 大文件夹 &gt;100MB" IsChecked="False"/>
        <ToggleButton x:Name="CbWinOld"    Style="{StaticResource Chip}" Content="🗂️ Windows.old（风险）" IsChecked="False"/>
      </WrapPanel>
      <Button x:Name="BtnScan" Grid.Column="1" Style="{StaticResource PrimaryBtn}" Content="🔍 开始扫描"
              VerticalAlignment="Center" Margin="10,0,0,0" MinWidth="130" Height="38"/>
    </Grid>

    <!-- 进度卡片：进度条 + 当前步骤 + 正在扫的路径 + 计数 -->
    <Border Grid.Row="3" Style="{StaticResource Card}" Padding="16,12" Margin="0,0,0,12">
      <StackPanel>
        <ProgressBar x:Name="Pb" Height="10" Minimum="0" Maximum="100" Value="0" Foreground="#2563EB" Background="#EceeF1" BorderThickness="0"/>
        <Grid Margin="0,8,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="TxtStep" Grid.Column="0" Text="勾选要扫描的内容，然后点「开始扫描」。" FontSize="13" FontWeight="SemiBold" Foreground="#1F2933" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="TxtCount" Grid.Column="1" Margin="10,0,0,0" Text="" FontSize="12" Foreground="#6B7280"/>
        </Grid>
        <TextBlock x:Name="TxtPath" Text="" FontSize="11" Foreground="#9CA3AF" TextTrimming="CharacterEllipsis" Margin="0,3,0,0"/>
      </StackPanel>
    </Border>

    <!-- 结果列表（按类别分组） -->
    <Border Grid.Row="4" Style="{StaticResource Card}" Padding="2">
      <DataGrid x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False" HeadersVisibility="Column"
                GridLinesVisibility="None" RowHeaderWidth="0" AlternationCount="2"
                Background="White" BorderThickness="0" RowHeight="32" FontSize="13"
                ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Auto"
                VirtualizingPanel.IsVirtualizingWhenGrouping="True" VirtualizingPanel.ScrollUnit="Pixel">
        <!-- 列头：浅底、灰字、下面一条细线 -->
        <DataGrid.ColumnHeaderStyle>
          <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#F8FAFC"/>
            <Setter Property="Foreground" Value="#64748B"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Padding" Value="10,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="BorderBrush" Value="#E5E7EB"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
          </Style>
        </DataGrid.ColumnHeaderStyle>
        <!-- 单元格：去掉默认选中蓝底，让整行底色透出来 -->
        <DataGrid.CellStyle>
          <Style TargetType="DataGridCell">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Foreground" Value="#1F2933"/>
            <Setter Property="Padding" Value="2,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Style.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="Transparent"/>
                <Setter Property="Foreground" Value="#1F2933"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </DataGrid.CellStyle>
        <!-- 行：隔行浅底纹 + 悬停高亮 + 选中高亮；并带详细说明悬停窗 -->
        <DataGrid.RowStyle>
          <Style TargetType="DataGridRow">
            <Setter Property="Background" Value="White"/>
            <Setter Property="ToolTip">
              <Setter.Value>
                <ToolTip MaxWidth="460" Background="#1F2933" Foreground="White" BorderThickness="0" Padding="12,9">
                  <TextBlock Text="{Binding Tip}" TextWrapping="Wrap" FontSize="12" LineHeight="18"/>
                </ToolTip>
              </Setter.Value>
            </Setter>
            <Setter Property="ToolTipService.InitialShowDelay" Value="350"/>
            <Setter Property="ToolTipService.ShowDuration" Value="30000"/>
            <Style.Triggers>
              <Trigger Property="ItemsControl.AlternationIndex" Value="1">
                <Setter Property="Background" Value="#F9FAFB"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Background" Value="#EFF6FF"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#DBEAFE"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </DataGrid.RowStyle>
        <DataGrid.Columns>
          <DataGridCheckBoxColumn Header="" Binding="{Binding Checked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="40"/>
          <DataGridTemplateColumn Header="标记" Width="100" SortMemberPath="Safety">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <Border x:Name="pill" CornerRadius="9" Padding="9,2" Margin="2,0" HorizontalAlignment="Left" VerticalAlignment="Center" Background="#FEF3C7">
                  <TextBlock x:Name="pillText" Text="{Binding MarkText}" FontSize="11.5" FontWeight="SemiBold" Foreground="#92400E"/>
                </Border>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding Safety}" Value="Green">
                    <Setter TargetName="pill" Property="Background" Value="#DCFCE7"/>
                    <Setter TargetName="pillText" Property="Foreground" Value="#166534"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Safety}" Value="Red">
                    <Setter TargetName="pill" Property="Background" Value="#FEE2E2"/>
                    <Setter TargetName="pillText" Property="Foreground" Value="#991B1B"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding MarkText}" Value="">
                    <Setter TargetName="pill" Property="Visibility" Value="Collapsed"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTextColumn Header="名称 / 路径" Binding="{Binding DisplayName}" Width="460" IsReadOnly="True"/>
          <DataGridTextColumn Header="大小" Binding="{Binding SizeText}" SortMemberPath="SizeBytes" Width="90" IsReadOnly="True"/>
          <DataGridTextColumn Header="说明" Binding="{Binding Reason}" Width="130" IsReadOnly="True"/>
        </DataGrid.Columns>
        <DataGrid.GroupStyle>
          <GroupStyle>
            <GroupStyle.ContainerStyle>
              <Style TargetType="{x:Type GroupItem}">
                <Setter Property="Template">
                  <Setter.Value>
                    <ControlTemplate TargetType="{x:Type GroupItem}">
                      <Expander IsExpanded="True" Background="Transparent" BorderThickness="0" Margin="0,4,0,0"
                                HorizontalAlignment="Stretch" HorizontalContentAlignment="Stretch">
                        <Expander.Header>
                          <Border Background="#EEF2F8" CornerRadius="7" Padding="6,5" Margin="0,0,0,2">
                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                              <Border Width="4" Height="15" Background="#2563EB" CornerRadius="2" Margin="2,0,9,0" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding Name}" FontWeight="Bold" FontSize="13.5" Foreground="#0F172A" VerticalAlignment="Center"/>
                              <Border Background="#2563EB" CornerRadius="9" Padding="8,1" Margin="10,0,0,0" VerticalAlignment="Center">
                                <StackPanel Orientation="Horizontal">
                                  <TextBlock Text="{Binding ItemCount}" Foreground="White" FontWeight="SemiBold" FontSize="11"/>
                                  <TextBlock Text=" 项" Foreground="White" FontSize="11"/>
                                </StackPanel>
                              </Border>
                            </StackPanel>
                          </Border>
                        </Expander.Header>
                        <ItemsPresenter/>
                      </Expander>
                    </ControlTemplate>
                  </Setter.Value>
                </Setter>
              </Style>
            </GroupStyle.ContainerStyle>
          </GroupStyle>
        </DataGrid.GroupStyle>
      </DataGrid>
    </Border>

    <!-- 底部操作 -->
    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <TextBlock x:Name="TxtSelected" VerticalAlignment="Center" Margin="0,0,16,0" FontSize="14" FontWeight="SemiBold" Foreground="#111827"/>
      <Button x:Name="BtnClean" Style="{StaticResource PrimaryBtn}" Content="🧹 清理选中项" Background="#DC2626" MinWidth="140" Height="40"/>
    </StackPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

$diskPanel = $win.FindName('DiskPanel')
$grid      = $win.FindName('Grid')
$pb        = $win.FindName('Pb')
$txtStep   = $win.FindName('TxtStep')
$txtPath   = $win.FindName('TxtPath')
$txtCount  = $win.FindName('TxtCount')
$txtSel    = $win.FindName('TxtSelected')
$btnScan   = $win.FindName('BtnScan')
$btnClean  = $win.FindName('BtnClean')
$cbTemp      = $win.FindName('CbTemp')
$cbRecycle   = $win.FindName('CbRecycle')
$cbBrowser   = $win.FindName('CbBrowser')
$cbLarge     = $win.FindName('CbLarge')
$cbLargeFolder = $win.FindName('CbLargeFolder')
$cbWinUpdate = $win.FindName('CbWinUpdate')
$cbCrash     = $win.FindName('CbCrash')
$cbThumb     = $win.FindName('CbThumb')
$cbLog       = $win.FindName('CbLog')
$cbWinOld    = $win.FindName('CbWinOld')

# ---------- 顶部磁盘卡片（带占用进度条）----------
$script:diskChecks = @()
foreach ($d in (Get-DiskList)) {
    $used = [long]$d.TotalBytes - [long]$d.FreeBytes
    $pct  = if ($d.TotalBytes -gt 0) { [math]::Round($used * 100.0 / $d.TotalBytes) } else { 0 }
    $barColor = if ($pct -ge 90) { '#DC2626' } elseif ($pct -ge 75) { '#F59E0B' } else { '#2563EB' }

    $card = New-Object System.Windows.Controls.Border
    $card.Style = $win.FindName('Grid').FindResource('Card')
    $card.Padding = '12,10'; $card.Margin = '0,0,10,0'; $card.Width = 190

    $sp = New-Object System.Windows.Controls.StackPanel

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = "$($d.Drive) 盘"
    $cb.FontWeight = 'SemiBold'; $cb.FontSize = 14; $cb.Foreground = (B '#111827')
    $cb.Tag = $d.Drive
    if ($d.Drive -eq 'C:') { $cb.IsChecked = $true }

    $bar = New-Object System.Windows.Controls.ProgressBar
    $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = $pct; $bar.Height = 7
    $bar.Margin = '0,8,0,4'; $bar.Foreground = (B $barColor); $bar.Background = (B '#EceeF1'); $bar.BorderThickness = 0

    $info = New-Object System.Windows.Controls.TextBlock
    $info.Text = "已用 $($pct)% · 可用 $(Format-Size ([long]$d.FreeBytes)) / 共 $(Format-Size ([long]$d.TotalBytes))"
    $info.FontSize = 11; $info.Foreground = (B '#6B7280'); $info.TextTrimming = 'CharacterEllipsis'

    [void]$sp.Children.Add($cb)
    [void]$sp.Children.Add($bar)
    [void]$sp.Children.Add($info)
    $card.Child = $sp
    $diskPanel.AddChild($card)
    $script:diskChecks += $cb
}

# ---------- 结果集合 + 分组视图 ----------
$script:rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$grid.ItemsSource = $script:rows
$view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:rows)
$view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription 'GroupName'))

# ---------- 右键菜单：打开文件所在位置 ----------
# 打开某一项对应的位置：文件→打开所在文件夹并选中它；文件夹→直接打开；回收站→打开回收站。
function Open-ItemLocation($src) {
    if (-not $src) { return }
    try {
        if ($src.Category -eq 'RecycleBin') {
            Start-Process explorer.exe 'shell:RecycleBinFolder'
            return
        }
        $path = [string]$src.Path
        if (-not $path) {
            [System.Windows.MessageBox]::Show('这一项没有对应的文件位置可以打开。', '提示') | Out-Null
            return
        }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Start-Process explorer.exe ('/select,"{0}"' -f $path)      # 文件：打开文件夹并高亮选中
        } elseif (Test-Path -LiteralPath $path -PathType Container) {
            Start-Process explorer.exe ('"{0}"' -f $path)              # 文件夹：直接打开
        } else {
            [System.Windows.MessageBox]::Show("找不到这个位置（可能已经被删掉了）：`n$path", '提示') | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show('打开位置失败：' + $_.Exception.Message, '提示') | Out-Null
    }
}

$rowMenu = New-Object System.Windows.Controls.ContextMenu
$miOpenLoc = New-Object System.Windows.Controls.MenuItem
$miOpenLoc.Header = '📂 打开文件所在位置'
[void]$rowMenu.Items.Add($miOpenLoc)
$grid.ContextMenu = $rowMenu

# DataGrid 默认右键不会选中那一行，这里手动把光标所在的行选上，菜单才知道对哪一项
$grid.Add_PreviewMouseRightButtonDown({
    param($s, $e)
    $dep = $e.OriginalSource
    while ($dep -and $dep -isnot [System.Windows.Controls.DataGridRow]) {
        $dep = [System.Windows.Media.VisualTreeHelper]::GetParent($dep)
    }
    if ($dep) { $dep.IsSelected = $true }
})

$miOpenLoc.Add_Click({
    $row = $grid.SelectedItem
    if ($row -and $row.Source) { Open-ItemLocation $row.Source }
})

# 点列头「大小」按真实字节数排序，可逆三段式：
#   第 1 下 → 从大到小；第 2 下 → 从小到大；第 3 下 → 切回默认（已勾选→新增→修改→大小）。
$script:sizeSort = 'none'
$grid.Add_Sorting({
    param($s, $e)
    if ($e.Column.SortMemberPath -ne 'SizeBytes') { return }   # 只接管「大小」列，其余列走默认
    $e.Handled = $true
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($grid.ItemsSource)
    foreach ($c in $grid.Columns) { $c.SortDirection = $null }  # 清掉所有列的排序箭头
    $view.SortDescriptions.Clear()
    if ($script:sizeSort -eq 'none') {
        $script:sizeSort = 'desc'
        $e.Column.SortDirection = [System.ComponentModel.ListSortDirection]::Descending
        $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('SizeBytes', [System.ComponentModel.ListSortDirection]::Descending)))
    } elseif ($script:sizeSort -eq 'desc') {
        $script:sizeSort = 'asc'
        $e.Column.SortDirection = [System.ComponentModel.ListSortDirection]::Ascending
        $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('SizeBytes', [System.ComponentModel.ListSortDirection]::Ascending)))
    } else {
        # 切回默认：清掉排序后，集合会回到我们手动排好的「已勾选→新增→修改→大小」顺序
        $script:sizeSort = 'none'
    }
    $view.Refresh()
})

# 分组表的「*」自适应列在边扫边加行时会塌缩，这里改成：名称列固定宽，
# 但按表格实际宽度实时算出来（其余列 40+100+90+130=360，再留出滚动条/边距）。
# 固定宽的列不会塌，于是既自适应窗口、又永远撑满。
function Update-NameColWidth {
    if ($grid.ActualWidth -le 0) { return }
    $avail = $grid.ActualWidth - 360 - 24
    if ($avail -lt 220) { $avail = 220 }
    $grid.Columns[2].Width = New-Object System.Windows.Controls.DataGridLength([double]$avail)
}
$grid.Add_SizeChanged({ Update-NameColWidth })
$grid.Add_Loaded({ Update-NameColWidth })

function Update-SelectedTotal {
    $sum = [long]0; $n = 0
    foreach ($r in $script:rows) { if ($r.Checked) { $sum += [long]$r.SizeBytes; $n++ } }
    $txtSel.Text = "已选 $n 项 · $(Format-Size $sum)"
}
Update-SelectedTotal

function Get-RowTip($item) {
    switch ($item.Category) {
        'Temp'         { "🧽 系统临时文件`n程序运行时产生的垃圾文件，删掉不影响使用，系统之后会自动重建。`n位置：$($item.Path)" }
        'RecycleBin'   { "🗑 回收站`n你之前删进回收站的东西。清空 = 彻底删除、无法再找回，请先确认里面没有还想保留的。" }
        'BrowserCache' { "🌐 浏览器缓存`n浏览器为了打开网页更快而存的临时文件。删掉不影响账号登录和收藏，只是下次访问网页会稍慢一点点。" }
        'WinUpdate'    { "♻️ Windows 更新缓存`nWindows 下载更新时攒下的安装包，装完就没用了。删掉系统需要时会自动重下，安全。`n位置：$($item.Path)" }
        'CrashDump'    { "💥 崩溃转储 / 错误报告`n程序或系统崩溃时留下的诊断文件（含蓝屏的 MEMORY.DMP）。普通使用用不上，删掉安全。" }
        'Thumbnails'   { "🖼️ 缩略图 / 图标缓存`n文件夹里图片、视频的预览小图缓存。删掉后下次打开文件夹会自动重建，安全。" }
        'SysLog'       { "📜 系统日志`nWindows 各种运行日志。删掉不影响使用（正在写入、占用中的会自动跳过）。" }
        'WindowsOld'   { "🗂️ Windows.old 旧系统`n系统升级后保留的旧版本备份，常有 10~20GB。`n⚠ 删了就无法再回退到升级前的旧系统，确认不需要回退再删。`n位置：$($item.Path)" }
        'LargeFile'    { Get-FileTip $item ([datetime]::Now) }
        'LargeFolder'  {
            $when = if ($item.LastUsed) { '最近改动 ' + ([datetime]$item.LastUsed).ToString('yyyy-MM-dd') + '（' + (Get-IdleDescription $item.LastUsed ([datetime]::Now)) + '）' } else { '' }
            $warn = switch ($item.RootRisk) {
                'Program' { '⚠ 这是已安装程序的目录，直接删可能留下残余、删坏程序。更稳妥是去「设置 → 应用」里卸载；确实要删会删到回收站、可找回。' }
                'AppData' { '⚠ 这是某程序存在 AppData/ProgramData 里的数据或缓存，整个删掉后那程序可能要重新登录、重下数据或丢设置。删到回收站、可找回。' }
                default   { '⚠ 这是你自己的整个文件夹，确认里面所有东西都不要了再删；删到回收站、可找回。' }
            }
            "🗂️ 整个文件夹：$($item.DisplayName)`n📂 位置：$($item.RootLabel)`n📁 路径：$($item.Path)`n📦 整个文件夹共 $(Format-Size $item.SizeBytes)，里面所有文件会一起清掉$(if($when){"`n🕒 $when"})`n$warn"
        }
        default        { $item.DisplayName }
    }
}

function Convert-ToRow {
    param($item)
    Set-SafetyMark $item ([datetime]::Now) | Out-Null
    $markText = switch ($item.Safety) { 'Green' {'可放心删'} 'Yellow' {'建议确认'} 'Red' {'谨慎'} default {''} }
    # 大文件：按所在文件夹分组，行内只显文件名（完整路径在悬停说明里）
    if ($item.Category -eq 'LargeFile') {
        $dir = [System.IO.Path]::GetDirectoryName($item.Path)
        if (-not $dir) { $dir = $item.Path }
        $group   = '📁 ' + $dir
        $display = [System.IO.Path]::GetFileName($item.Path)
        if (-not $display) { $display = $item.Path }
    } elseif ($item.Category -eq 'LargeFolder') {
        # 大文件夹：按所在位置（下载/桌面/AppData…）分组，行内显文件夹名
        $group   = '🗂️ 大文件夹 · ' + $item.RootLabel
        $display = $item.DisplayName
    } else {
        $group = switch ($item.Category) {
            'Temp'         { '🧽 系统临时文件' }
            'RecycleBin'   { '🗑 回收站' }
            'BrowserCache' { '🌐 浏览器缓存' }
            'WinUpdate'    { '♻️ Windows 更新缓存' }
            'CrashDump'    { '💥 崩溃转储 / 错误报告' }
            'Thumbnails'   { '🖼️ 缩略图 / 图标缓存' }
            'SysLog'       { '📜 系统日志' }
            'WindowsOld'   { '🗂️ Windows.old 旧系统' }
            default        { '其它' }
        }
        $display = $item.DisplayName
    }
    [PSCustomObject]@{
        Checked     = [bool]$item.DefaultChecked
        Safety      = $item.Safety
        MarkText    = $markText
        DisplayName = $display
        SizeText    = Format-Size $item.SizeBytes
        Reason      = $item.Reason
        SizeBytes   = $item.SizeBytes
        GroupName   = $group
        Tip         = Get-RowTip $item
        Source      = $item
    }
}

# 排序时统一取时间的小工具：空值当成最早，保证排序不报错、空值垫底
function Get-RowTime($v) { if ($v) { [datetime]$v } else { [datetime]::MinValue } }

# 一批行按「新增 → 修改 → 大小」从新/大到旧/小排
function Sort-RowsRecent($rows) {
    @($rows | Sort-Object `
        @{ Expression = { Get-RowTime $_.Source.CreationTime }; Descending = $true },
        @{ Expression = { Get-RowTime $_.Source.LastUsed };     Descending = $true },
        @{ Expression = { [long]$_.SizeBytes };                 Descending = $true })
}

# 扫描完成后整理列表，分两段，整体落实「已勾选 → 新增 → 修改 → 大小」：
#   1) 已勾选（默认该删的绿色可回收项：系统垃圾/回收站/各种缓存）排最前，保持各自类别顺序；
#   2) 其余（大文件夹/大文件/Windows.old…）按所属组归堆，所有组放一起，
#      组之间按「组里最新的那一条」从新到旧排，组内按「新增 → 修改 → 大小」排。
#   这样大文件夹组和大文件组会按时间穿插，最新的真的浮到最顶；组标题补总大小。
function Optimize-ResultLayout {
    $all   = @($script:rows)
    if ($all.Count -eq 0) { return }
    $green = @($all | Where-Object { $_.Source.Safety -eq 'Green' })   # 默认勾选、可放心删
    $rest  = @($all | Where-Object { $_.Source.Safety -ne 'Green' })   # 需要你确认的
    if ($rest.Count -eq 0) { return }   # 全是绿色可回收项，无需重排，保持原样

    # 通用：把一批行按某个「分组键」归组，每组算总大小和最新时间，组间按 最新时间 → 总大小 排
    function Group-AndSort($rows, [scriptblock]$KeyOf) {
        $byKey = @{}
        foreach ($r in $rows) {
            $k = & $KeyOf $r
            if (-not $byKey.ContainsKey($k)) { $byKey[$k] = New-Object System.Collections.ArrayList }
            [void]$byKey[$k].Add($r)
        }
        $groups = foreach ($k in $byKey.Keys) {
            $sum = [long]0; $newest = [datetime]::MinValue
            foreach ($r in $byKey[$k]) {
                $sum += [long]$r.SizeBytes
                $ct = Get-RowTime $r.Source.CreationTime
                if ($ct -gt $newest) { $newest = $ct }
            }
            [PSCustomObject]@{ Key = $k; Total = $sum; Newest = $newest; Rows = $byKey[$k] }
        }
        @($groups | Sort-Object `
            @{ Expression = { $_.Newest };     Descending = $true },
            @{ Expression = { [long]$_.Total }; Descending = $true })
    }

    $script:rows.Clear()
    # 第 1 段：绿色可回收项排最前（保持扫描时的类别顺序）
    foreach ($r in $green) { $script:rows.Add($r) }
    # 第 2 段：其余所有组放一起，按「组里最新那条」穿插排序
    foreach ($g in (Group-AndSort $rest { param($r) $r.GroupName })) {
        $gname = $g.Key + '  ·  共 ' + (Format-Size $g.Total)
        foreach ($r in (Sort-RowsRecent $g.Rows)) { $r.GroupName = $gname; $script:rows.Add($r) }
    }
}

# ---------- 通用后台执行器：开后台线程跑活，UI 用定时器轮询进度 ----------
function Invoke-Background {
    param(
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$Vars = @{},
        [Parameter(Mandatory)][scriptblock]$OnTick,
        [Parameter(Mandatory)][scriptblock]$OnDone
    )
    $sync = [hashtable]::Synchronized(@{})
    $sync.Queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    $sync.Status = ''; $sync.CurrentPath = ''; $sync.Progress = 0; $sync.Indeterminate = $false
    $sync.FoundCount = 0; $sync.FilesSeen = 0; $sync.Cancel = $false; $sync.Done = $false; $sync.Error = $null

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'         # Shell.Application 等 COM 需要 STA
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script)
    $handle = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        & $OnTick $sync
        if ($sync.Done) {
            $timer.Stop()
            try { $ps.EndInvoke($handle) } catch { }
            $ps.Dispose(); $rs.Close(); $rs.Dispose()
            & $OnDone $sync
        }
    }.GetNewClosure())
    $timer.Start()
    return $sync
}

# ---------- 扫描：后台脚本 ----------
$scanScriptText = @'
try {
  $mp = $opt.ModPath
  Import-Module (Join-Path $mp 'Analyzer.psm1')     -Force
  Import-Module (Join-Path $mp 'TempCleaner.psm1')  -Force
  Import-Module (Join-Path $mp 'BrowserCache.psm1') -Force
  Import-Module (Join-Path $mp 'RecycleBin.psm1')   -Force
  Import-Module (Join-Path $mp 'SystemJunk.psm1')   -Force
  Import-Module (Join-Path $mp 'LargeFolders.psm1') -Force

  function Enqueue($it) { if ($it) { $sync.Queue.Enqueue($it); $sync.FoundCount = $sync.FoundCount + 1 } }

  $quickCount = 0
  if ($opt.Temp)       { $quickCount++ }
  if ($opt.Recycle)    { $quickCount++ }
  if ($opt.Browser)    { $quickCount++ }
  if ($opt.WinUpdate)  { $quickCount++ }
  if ($opt.CrashDump)  { $quickCount++ }
  if ($opt.Thumbnails) { $quickCount++ }
  if ($opt.SysLog)     { $quickCount++ }
  if ($opt.WindowsOld) { $quickCount++ }
  $hasLarge  = $opt.Large -and $opt.Drives -and $opt.Drives.Count -gt 0
  $hasFolder = [bool]$opt.LargeFolder
  $budget = if ($hasLarge -or $hasFolder) { 50.0 } else { 100.0 }
  $per = if ($quickCount -gt 0) { $budget / $quickCount } else { 0 }
  $done = 0

  if ($opt.Temp) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描系统临时文件…'; $sync.Indeterminate = $true; $sync.CurrentPath = $env:TEMP
    foreach ($it in (Get-TempItems)) { Enqueue $it }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.Recycle) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描回收站…'; $sync.Indeterminate = $true; $sync.CurrentPath = '回收站'
    $r = Get-RecycleBinItem; if ($r) { Enqueue $r }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.Browser) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描浏览器缓存…'; $sync.Indeterminate = $true; $sync.CurrentPath = "$env:LOCALAPPDATA\...\Cache"
    foreach ($it in (Get-BrowserCacheItems)) { Enqueue $it }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.WinUpdate) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描 Windows 更新缓存…'; $sync.Indeterminate = $true; $sync.CurrentPath = (Join-Path $env:windir 'SoftwareDistribution')
    $x = Get-WinUpdateItem; if ($x) { Enqueue $x }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.CrashDump) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描崩溃转储 / 错误报告…'; $sync.Indeterminate = $true; $sync.CurrentPath = (Join-Path $env:windir 'Minidump')
    $x = Get-CrashDumpItem; if ($x) { Enqueue $x }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.Thumbnails) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描缩略图 / 图标缓存…'; $sync.Indeterminate = $true; $sync.CurrentPath = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer')
    $x = Get-ThumbnailItem; if ($x) { Enqueue $x }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.SysLog) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描系统日志…'; $sync.Indeterminate = $true; $sync.CurrentPath = (Join-Path $env:windir 'Logs')
    $x = Get-SysLogItem; if ($x) { Enqueue $x }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($opt.WindowsOld) {
    if ($sync.Cancel) { return }
    $sync.Status = '正在扫描 Windows.old 旧系统…'; $sync.Indeterminate = $true; $sync.CurrentPath = (Join-Path $env:SystemDrive 'Windows.old')
    $x = Get-WindowsOldItem; if ($x) { Enqueue $x }
    $done++; $sync.Indeterminate = $false; $sync.Progress = [int]($done * $per)
  }
  if ($hasFolder -and -not $sync.Cancel) {
    $sync.Status = '正在扫描大文件夹（按常堆东西的位置统计，稍候…）'; $sync.Indeterminate = $true
    $reparseF = [System.IO.FileAttributes]::ReparsePoint
    $minF = [long]$opt.MinBytes
    foreach ($root in (Get-LargeFolderRoots)) {
      if ($sync.Cancel) { break }
      $sync.CurrentPath = $root.Path
      $subs = @()
      try { $subs = @([System.IO.Directory]::EnumerateDirectories($root.Path)) } catch { $subs = @() }
      foreach ($sub in $subs) {
        if ($sync.Cancel) { break }
        $sync.CurrentPath = $sub
        # 跳过 junction/符号链接，免得顺着链接乱算
        try { if (([System.IO.File]::GetAttributes($sub) -band $reparseF) -ne 0) { continue } } catch { continue }
        $sync.FilesSeen = $sync.FilesSeen + 1
        $it = New-LargeFolderItem -Path $sub -RootLabel $root.Label -RootRisk $root.Risk -MinBytes $minF
        if ($it) { Enqueue $it }
      }
    }
    $sync.Indeterminate = $false
  }
  if ($hasLarge) {
    $sync.Status = '正在扫描大文件（>100MB），这步最慢，请稍候…'; $sync.Indeterminate = $true
    $min = [long]$opt.MinBytes
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    foreach ($drive in $opt.Drives) {
      if ($sync.Cancel) { break }
      $root = "$drive\"
      if (-not (Test-Path -LiteralPath $root)) { continue }
      $stack = New-Object System.Collections.Stack
      $stack.Push($root)
      while ($stack.Count -gt 0) {
        if ($sync.Cancel) { break }
        $dir = $stack.Pop()
        $sync.CurrentPath = $dir
        # 子目录入栈（跳过 junction/符号链接，避免死循环）
        try {
          foreach ($sd in [System.IO.Directory]::EnumerateDirectories($dir)) {
            try { if (([System.IO.File]::GetAttributes($sd) -band $reparse) -ne 0) { continue } } catch { continue }
            $stack.Push($sd)
          }
        } catch { }
        # 本目录文件
        try {
          foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) {
            if ($sync.Cancel) { break }
            $sync.FilesSeen = $sync.FilesSeen + 1
            try {
              $fi = New-Object System.IO.FileInfo $f
              if ($fi.Length -ge $min) {
                # 顺手探一下文件是不是正被别的程序占用着（占用的删不掉）。
                # 用「独占只读」方式打开试试：能开=没被占；开不了(IOException)=被占；其它(没权限等)=未知。
                $inUse = $null
                try {
                  $fsx = [System.IO.File]::Open($f, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                  $fsx.Close(); $fsx.Dispose(); $inUse = $false
                } catch [System.IO.IOException] { $inUse = $true } catch { $inUse = $null }
                Enqueue ([PSCustomObject]@{
                  Path           = $f
                  DisplayName    = $f
                  Category       = 'LargeFile'
                  SizeBytes      = [long]$fi.Length
                  LastUsed       = $fi.LastWriteTime
                  CreationTime   = $fi.CreationTime
                  LastAccessTime = $fi.LastAccessTime
                  InUse          = $inUse
                })
              }
            } catch { }
          }
        } catch { }
      }
    }
    $sync.Indeterminate = $false; $sync.Progress = 100
  }
} catch {
  $sync.Error = $_.Exception.Message
} finally {
  $sync.Progress = 100
  $sync.Done = $true
}
'@

# ---------- 扫描：UI 轮询 ----------
$onScanTick = {
    param($s)
    $drained = 0
    while ($s.Queue.Count -gt 0 -and $drained -lt 300) {
        $script:rows.Add((Convert-ToRow $s.Queue.Dequeue())); $drained++
    }
    $pb.IsIndeterminate = [bool]$s.Indeterminate
    if (-not $s.Indeterminate) { $pb.Value = [double]$s.Progress }
    $txtStep.Text  = [string]$s.Status
    $txtPath.Text  = if ([string]$s.CurrentPath) { '📂 正在查看：' + $s.CurrentPath } else { '' }
    $txtCount.Text = "已找到 $($s.FoundCount) 项 · 已翻看 $($s.FilesSeen) 个文件"
    Update-SelectedTotal
}
$onScanDone = {
    param($s)
    while ($s.Queue.Count -gt 0) { $script:rows.Add((Convert-ToRow $s.Queue.Dequeue())) }
    Optimize-ResultLayout   # 大文件夹/大文件按位置归组、补总大小、最新的排最前
    $script:scanning = $false
    Set-ScanButtonScanning $false
    $btnClean.IsEnabled = $true
    $pb.IsIndeterminate = $false
    if ($s.Error) {
        $txtStep.Text = '扫描出错：' + $s.Error; $pb.Value = 0
    } elseif ($s.Cancel) {
        $txtStep.Text = "⏹ 已取消，已找到 $($script:rows.Count) 项"
    } else {
        $txtStep.Text = "✅ 扫描完成，共找到 $($script:rows.Count) 项"; $pb.Value = 100; $txtPath.Text = ''
    }
    $txtCount.Text = "已找到 $($s.FoundCount) 项 · 共翻看 $($s.FilesSeen) 个文件"
    Update-SelectedTotal
}

function Set-ScanButtonScanning([bool]$on) {
    if ($on) { $btnScan.Content = '⏹ 取消扫描'; $btnScan.Background = (B '#6B7280') }
    else     { $btnScan.Content = '🔍 开始扫描'; $btnScan.Background = (B '#2563EB') }
}

$btnScan.Add_Click({
    if ($script:scanning) {
        if ($script:scanSync) { $script:scanSync.Cancel = $true }
        $txtStep.Text = '正在取消…'
        return
    }
    $script:rows.Clear()
    # 复位排序：新扫一遍总是先按默认「已勾选→新增→修改→大小」展示，不沿用上次点的大小排序
    $script:sizeSort = 'none'
    $defView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:rows)
    $defView.SortDescriptions.Clear()
    foreach ($c in $grid.Columns) { $c.SortDirection = $null }
    $selectedDrives = @($script:diskChecks | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
    $opt = @{
        Temp       = [bool]$cbTemp.IsChecked
        Recycle    = [bool]$cbRecycle.IsChecked
        Browser    = [bool]$cbBrowser.IsChecked
        WinUpdate  = [bool]$cbWinUpdate.IsChecked
        CrashDump  = [bool]$cbCrash.IsChecked
        Thumbnails = [bool]$cbThumb.IsChecked
        SysLog     = [bool]$cbLog.IsChecked
        WindowsOld = [bool]$cbWinOld.IsChecked
        Large       = [bool]$cbLarge.IsChecked
        LargeFolder = [bool]$cbLargeFolder.IsChecked
        Drives      = $selectedDrives
        MinBytes    = [long]100MB
        ModPath     = $mod
    }
    $anyQuick = $opt.Temp -or $opt.Recycle -or $opt.Browser -or $opt.WinUpdate -or $opt.CrashDump -or $opt.Thumbnails -or $opt.SysLog -or $opt.WindowsOld
    if (-not ($anyQuick -or $opt.LargeFolder -or ($opt.Large -and $selectedDrives.Count -gt 0))) {
        [System.Windows.MessageBox]::Show('请至少勾选一类要扫描的内容（扫大文件还要先勾选磁盘）。', '提示') | Out-Null
        return
    }
    $pb.Value = 0; $pb.IsIndeterminate = $false
    $txtStep.Text = '准备中…'; $txtPath.Text = ''; $txtCount.Text = ''
    $script:scanning = $true
    Set-ScanButtonScanning $true
    $btnClean.IsEnabled = $false
    $script:scanSync = Invoke-Background -Script $scanScriptText -Vars @{ opt = $opt } -OnTick $onScanTick -OnDone $onScanDone
})

# ---------- 清理：后台脚本 ----------
$cleanScriptText = @'
try {
  Import-Module (Join-Path $modPath 'Remover.psm1')   -Force
  Import-Module (Join-Path $modPath 'RecycleBin.psm1') -Force
  $total = @($items).Count; $i = 0; $ok = 0; $skip = 0; $freed = [long]0
  $killedAll = @()

  $needBrowser = $false
  foreach ($it in $items) { if ($it.Category -eq 'BrowserCache') { $needBrowser = $true } }
  if ($needBrowser) { $sync.Status = '正在关闭浏览器以释放缓存…'; $sync.Indeterminate = $true; Stop-OccupyingBrowser; $sync.Indeterminate = $false }

  foreach ($it in $items) {
    $i++
    $sync.Progress = [int]($i * 100.0 / [math]::Max(1, $total))
    $sync.Status = "正在清理（$i/$total）：$($it.DisplayName)"
    $sync.CurrentPath = $it.Path
    switch ($it.Category) {
      'RecycleBin'   { Clear-AllRecycleBin; $ok++; $freed += [long]$it.SizeBytes }
      'LargeFolder'  {
        # 整个文件夹只删到回收站、不强删不杀进程，保证随时能找回；占用着就跳过
        $r = Remove-ToRecycleBin $it.Path
        if ($r.Success) { $ok++; $freed += [long]$it.SizeBytes } else { $skip++ }
      }
      'BrowserCache' {
        $allok = $true
        foreach ($c in $it.CacheDirs) {
          $r = Remove-ToRecycleBin $c -Force
          if ($r.Killed) { $killedAll += $r.Killed }
          if (-not $r.Success) { $allok = $false }
        }
        if ($allok) { $ok++; $freed += [long]$it.SizeBytes } else { $skip++ }
      }
      default {
        if ($it.Targets) {
          # 系统垃圾类：要删的是 Targets 里的多个文件夹/文件
          $allok = $true
          foreach ($tp in $it.Targets) {
            if (Test-Path -LiteralPath $tp) {
              $r = Remove-ToRecycleBin $tp -Force
              if ($r.Killed) { $killedAll += $r.Killed }
              if (-not $r.Success) { $allok = $false }
            }
          }
          if ($allok) { $ok++; $freed += [long]$it.SizeBytes } else { $skip++ }
        } else {
          $res = Remove-ToRecycleBin $it.Path -Force
          if ($res.Killed) {
            $killedAll += $res.Killed
            $sync.Status = "已关闭占用程序（$([string]::Join('、', $res.Killed))），继续清理…"
          }
          if ($res.Success) { $ok++; $freed += [long]$it.SizeBytes } else { $skip++ }
        }
      }
    }
  }
  $sync.OkCount = $ok; $sync.SkipCount = $skip; $sync.Freed = $freed
  $sync.Killed = @($killedAll | Select-Object -Unique) -join '、'
} catch {
  $sync.Error = $_.Exception.Message
} finally {
  $sync.Progress = 100; $sync.Done = $true
}
'@

$onCleanTick = {
    param($s)
    $pb.IsIndeterminate = [bool]$s.Indeterminate
    if (-not $s.Indeterminate) { $pb.Value = [double]$s.Progress }
    $txtStep.Text = [string]$s.Status
    $txtPath.Text = if ([string]$s.CurrentPath) { '📂 ' + $s.CurrentPath } else { '' }
}
$onCleanDone = {
    param($s)
    $script:cleaning = $false
    $btnClean.IsEnabled = $true; $btnScan.IsEnabled = $true
    $pb.IsIndeterminate = $false; $pb.Value = 0; $txtPath.Text = ''
    if ($s.Error) {
        $txtStep.Text = '清理出错：' + $s.Error
        [System.Windows.MessageBox]::Show('清理出错：' + $s.Error, '错误') | Out-Null
    } else {
        $msg = "清理完成：成功 $($s.OkCount) 项，释放约 $(Format-Size ([long]$s.Freed))。"
        if ([string]$s.Killed) { $msg += "`n为清理被占用的文件，已关闭：$($s.Killed)。" }
        if ([int]$s.SkipCount -gt 0) { $msg += "`n仍有 $($s.SkipCount) 项删不掉（可能被系统关键进程占用，已为安全跳过）。" }
        $txtStep.Text = '✅ ' + $msg.Replace("`n", '  ')
        [System.Windows.MessageBox]::Show($msg, '完成') | Out-Null
        # 清完自动重扫一遍，方便核对释放效果
        $btnScan.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
    }
}

$btnClean.Add_Click({
    if ($script:scanning -or $script:cleaning) { return }
    $checked = @($script:rows | Where-Object { $_.Checked })
    if ($checked.Count -eq 0) { [System.Windows.MessageBox]::Show('没有勾选任何项', '提示') | Out-Null; return }
    $sum = [long](($checked | Measure-Object -Property SizeBytes -Sum).Sum)
    $folders = @($checked | Where-Object { $_.Source.Category -eq 'LargeFolder' })
    $folderNote = if ($folders.Count -gt 0) {
        "`n其中有 $($folders.Count) 个是「整个文件夹」，会连里面所有文件一起删到回收站（可找回）。"
    } else { '' }
    $ans = [System.Windows.MessageBox]::Show(
        "将清理 $($checked.Count) 项，释放约 $(Format-Size $sum)。$folderNote`n遇到被占用的文件，会自动关掉占用它的程序再删（系统关键进程除外）。`n请先保存好正在编辑的内容，确定继续吗？",
        '确认清理', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    $sources = @($checked | ForEach-Object { $_.Source })
    $script:cleaning = $true
    $btnClean.IsEnabled = $false; $btnScan.IsEnabled = $false
    $pb.IsIndeterminate = $false; $pb.Value = 0; $txtStep.Text = '开始清理…'
    $script:cleanSync = Invoke-Background -Script $cleanScriptText -Vars @{ items = $sources; modPath = $mod } -OnTick $onCleanTick -OnDone $onCleanDone
})

$grid.Add_CellEditEnding({ $win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Update-SelectedTotal }) | Out-Null })

# 关窗时通知后台停下来，别让它白跑
$win.Add_Closing({
    if ($script:scanSync)  { $script:scanSync.Cancel  = $true }
    if ($script:cleanSync) { $script:cleanSync.Cancel = $true }
})

$win.ShowDialog() | Out-Null
