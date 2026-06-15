Add-Type -AssemblyName PresentationFramework

# 加载模块
$mod = Join-Path $PSScriptRoot '..\Modules'
'DesktopScanner', 'BackupManager', 'RestoreManager', 'SystemOptimizer', 'ReinstallManager', 'ImageManager' |
    ForEach-Object { Import-Module (Join-Path $mod "$_.psm1") -Force }

# 项目根：根据脚本所在位置自动算(src\UI 的上两级)，整个项目挪到哪都能跑
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$backupRoot = Join-Path $root 'backup'
$manifest = Join-Path $backupRoot 'manifest.json'
$imagesDir = Join-Path $root 'images'
$toolsDir = Join-Path $root 'tools'

# 重装方式选择子窗口：返回 'reset' / 'image' / $null
function Show-ReinstallChoice {
    [xml]$cx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="选择重装方式" Height="340" Width="540"
        WindowStartupLocation="CenterScreen" Background="#F5F7FA" FontFamily="Microsoft YaHei"
        ResizeMode="NoResize">
  <Grid Margin="20">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="请选择重装方式：" FontSize="15" Foreground="#334155" Margin="0,0,0,14"/>
    <Button x:Name="BtnR" Grid.Row="1" Height="74" Margin="0,0,0,12" Background="#2563EB" Foreground="White" BorderThickness="0" Cursor="Hand" HorizontalContentAlignment="Left">
      <StackPanel Margin="10,0">
        <TextBlock Text="重置此电脑" FontSize="16" FontWeight="Bold"/>
        <TextBlock Text="装回当前版本，最稳，无需镜像（可保留个人文件）" FontSize="12" Opacity="0.9" Margin="0,3,0,0"/>
      </StackPanel>
    </Button>
    <Button x:Name="BtnI" Grid.Row="2" Height="74" Background="#EA580C" Foreground="White" BorderThickness="0" Cursor="Hand" HorizontalContentAlignment="Left">
      <StackPanel Margin="10,0">
        <TextBlock Text="镜像装机（选版本）" FontSize="16" FontWeight="Bold"/>
        <TextBlock Text="用 ISO 选 Win10 / Win11 版本，会清盘全新装" FontSize="12" Opacity="0.9" Margin="0,3,0,0"/>
      </StackPanel>
    </Button>
    <Button x:Name="BtnC" Grid.Row="3" Content="取消" Width="92" Height="34" HorizontalAlignment="Right" VerticalAlignment="Bottom" Background="#E2E8F0" Foreground="#334155" BorderThickness="0" Cursor="Hand"/>
  </Grid>
</Window>
'@
    $cr = New-Object System.Xml.XmlNodeReader $cx
    $dlg = [Windows.Markup.XamlReader]::Load($cr)
    $script:rcResult = $null
    $dlg.FindName('BtnR').Add_Click({ $script:rcResult = 'reset'; $dlg.Close() })
    $dlg.FindName('BtnI').Add_Click({ $script:rcResult = 'image'; $dlg.Close() })
    $dlg.FindName('BtnC').Add_Click({ $script:rcResult = $null; $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
    return $script:rcResult
}

# 镜像版本选择子窗口：传入版本清单，返回用户选中的一项（或 $null）
function Show-VersionPicker($editions, $WindowTitle = '选择要安装的系统版本', $Prompt = '选一个版本，然后点【确定】：') {
    [xml]$px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="选择要安装的系统版本" Height="380" Width="580"
        WindowStartupLocation="CenterScreen" Background="#F5F7FA"
        FontFamily="Microsoft YaHei">
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock x:Name="Prompt" Grid.Row="0" Margin="0,0,0,10" FontSize="14" Foreground="#334155" Text="选一个版本，然后点【确定】："/>
    <Border Grid.Row="1" Background="White" CornerRadius="8" BorderBrush="#E2E8F0" BorderThickness="1" Padding="4">
      <ListBox x:Name="Lst" BorderThickness="0" DisplayMemberPath="Display" FontSize="14"/>
    </Border>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="Ok" Content="确定" Width="96" Height="36" Margin="0,0,8,0" Background="#2563EB" Foreground="White" BorderThickness="0" Cursor="Hand"/>
      <Button x:Name="Cancel" Content="取消" Width="96" Height="36" Background="#E2E8F0" Foreground="#334155" BorderThickness="0" Cursor="Hand"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $pr = New-Object System.Xml.XmlNodeReader $px
    $dlg = [Windows.Markup.XamlReader]::Load($pr)
    $dlg.Title = $WindowTitle
    $promptTb = $dlg.FindName('Prompt'); if ($promptTb) { $promptTb.Text = $Prompt }
    $lst = $dlg.FindName('Lst')
    foreach ($e in $editions) {
        $disp = if ($e.PSObject.Properties.Name -contains 'Title') { $e.Title }
        else { "$($e.Edition)   [ $($e.IsoName) ]   约$($e.SizeGB)GB" }
        $e | Add-Member -NotePropertyName Display -NotePropertyValue $disp -Force
        $lst.Items.Add($e) | Out-Null
    }
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $script:pickResult = $null
    $dlg.FindName('Ok').Add_Click({ $script:pickResult = $lst.SelectedItem; $dlg.Close() })
    $dlg.FindName('Cancel').Add_Click({ $script:pickResult = $null; $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
    return $script:pickResult
}

# 降级引导子窗口：小白图文步骤（Win11→Win10 需要 U 盘）
function Show-DowngradeGuide($sel, $toolsDir = $script:toolsDir) {
    [xml]$gx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="降级到 Win10 · 操作指引" Height="640" Width="680"
        WindowStartupLocation="CenterScreen" Background="#F5F7FA" FontFamily="Microsoft YaHei">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#EA580C" Padding="22,16">
      <StackPanel>
        <TextBlock Text="检测到「降级安装」：Win11 → Win10" Foreground="White" FontSize="19" FontWeight="Bold"/>
        <TextBlock Text="降级没法在系统里直接装，要用 U 盘从外面装。照下面 5 步做就行，不难。" Foreground="#FFE4D6" FontSize="13" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="16,14">
      <StackPanel>
        <Border Background="White" CornerRadius="10" Padding="14" Margin="0,0,0,10" BorderBrush="#E2E8F0" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="第 1 步：先备份(千万别跳过！)" FontSize="15" FontWeight="Bold" Foreground="#DC2626"/>
            <TextBlock TextWrapping="Wrap" FontSize="13.5" Foreground="#475569" Margin="0,6,0,0"
              Text="降级会把 C 盘(包括桌面)全部清空。先回主界面点【① 扫描桌面】→【② 备份选中】，东西会存到 E 盘，不会被清掉。"/>
          </StackPanel>
        </Border>
        <Border Background="White" CornerRadius="10" Padding="14" Margin="0,0,0,10" BorderBrush="#E2E8F0" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="第 2 步：做一个 Win10 启动 U 盘" FontSize="15" FontWeight="Bold" Foreground="#1E293B"/>
            <TextBlock x:Name="Step2Text" TextWrapping="Wrap" FontSize="13.5" Foreground="#475569" Margin="0,6,0,0"
              Text="准备一个 8GB 以上的 U 盘(里面东西会被清空，先把重要文件挪走)。双击运行微软官方 Win10 制盘工具 → 同意条款 → 选「为另一台电脑创建安装介质」→ 语言选简体中文、版本 Windows 10 → 选「U 盘」→ 选中你的 U 盘 → 等它做完(大约 10-30 分钟)。"/>
          </StackPanel>
        </Border>
        <Border Background="White" CornerRadius="10" Padding="14" Margin="0,0,0,10" BorderBrush="#E2E8F0" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="第 3 步：从 U 盘启动电脑" FontSize="15" FontWeight="Bold" Foreground="#1E293B"/>
            <TextBlock TextWrapping="Wrap" FontSize="13.5" Foreground="#475569" Margin="0,6,0,0"
              Text="U 盘插着不拔，重启电脑。开机一出现品牌 logo，就连续按「启动菜单键」(不同电脑不一样，常见是 F12 / F8 / Esc / F2，笔记本可能要配合 Fn 键)。在弹出的菜单里，用方向键选你的 U 盘(名字一般含 USB 或 U 盘品牌)，回车。"/>
          </StackPanel>
        </Border>
        <Border Background="White" CornerRadius="10" Padding="14" Margin="0,0,0,10" BorderBrush="#E2E8F0" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="第 4 步：安装 Win10" FontSize="15" FontWeight="Bold" Foreground="#1E293B"/>
            <TextBlock TextWrapping="Wrap" FontSize="13.5" Foreground="#475569" Margin="0,6,0,0"
              Text="进入安装界面 → 现在安装 → 提示密钥时点「我没有产品密钥」→ 选 Windows 10 专业版 → 勾选接受条款 → 选「自定义(高级)」→ 在分区列表里认准 C 盘的几个分区把它们删掉 → 选那块「未分配空间」→ 下一步。接下来它会自动安装、自动重启几次，耐心等着别断电。"/>
          </StackPanel>
        </Border>
        <Border Background="White" CornerRadius="10" Padding="14" Margin="0,0,0,10" BorderBrush="#E2E8F0" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="第 5 步：装完收尾" FontSize="15" FontWeight="Bold" Foreground="#16A34A"/>
            <TextBlock x:Name="Step5Text" TextWrapping="Wrap" FontSize="13.5" Foreground="#475569" Margin="0,6,0,0"
              Text="进入 Win10 桌面后：连上网、装好驱动、激活系统。然后打开本工具文件夹，双击【一键启动.bat】→ 点【④ 还原桌面】，你之前备份的桌面就回来了。"/>
          </StackPanel>
        </Border>
        <Border Background="#FEF2F2" CornerRadius="10" Padding="14" Margin="0,0,0,4" BorderBrush="#FECACA" BorderThickness="1">
          <TextBlock TextWrapping="Wrap" FontSize="13.5" Foreground="#B91C1C"
            Text="⚠ 最重要：第 4 步删分区时一定认准 C 盘的容量，别误删 D 盘或 E 盘 —— 你的备份和镜像都在 E 盘，删了就全没了！"/>
        </Border>
      </StackPanel>
    </ScrollViewer>
    <Border Grid.Row="2" Background="White" BorderBrush="#E2E8F0" BorderThickness="0,1,0,0" Padding="16,10">
      <Grid>
        <Button x:Name="BtnDownTool" Content="⬇ 帮我下载制盘工具" Height="36" Padding="14,0" HorizontalAlignment="Left" Background="#16A34A" Foreground="White" BorderThickness="0" Cursor="Hand"/>
        <Button x:Name="BtnClose" Content="我知道了" Width="110" Height="36" HorizontalAlignment="Right" Background="#2563EB" Foreground="White" BorderThickness="0" Cursor="Hand"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
    $gr = New-Object System.Xml.XmlNodeReader $gx
    $dlg = [Windows.Markup.XamlReader]::Load($gr)
    $t5 = $dlg.FindName('Step5Text')
    if ($t5 -and $script:root) {
        $t5.Text = "进入 Win10 桌面后：连上网、装好驱动、激活系统。然后打开本工具文件夹（$script:root），双击【一键启动.bat】→ 点【④ 还原桌面】，你之前备份的桌面就回来了。"
    }
    $t2 = $dlg.FindName('Step2Text')
    $verName = "Windows $($sel.Major)"
    $defFile = if ($sel.Major -eq 11) { 'MediaCreationTool_Win11.exe' } else { 'MediaCreationTool_22H2.exe' }
    $defPath = Join-Path $toolsDir $defFile

    # 按"工具是否已在本地"刷新第 2 步文案
    $setStep2 = {
        param($path)
        if (-not $t2) { return }
        $head = if (Test-Path -LiteralPath $path) { "双击运行已下载好的微软官方制盘工具：`n$path`n" }
        else { "点下方绿色【⬇ 帮我下载制盘工具】，下完后双击运行它：`n" }
        $t2.Text = "准备一个 8GB 以上的 U 盘(里面东西会被清空，先把重要文件挪走)。$head→ 同意条款 → 选「为另一台电脑创建安装介质」→ 语言选简体中文、版本 $verName → 选「U 盘」→ 选中你的 U 盘 → 等它做完(大约 10-30 分钟)。"
    }
    & $setStep2 $defPath

    # 下载按钮：弹版本(含官方地址)选择 → 下载对应制盘工具 → 刷新文案 + 可打开文件夹
    $dlg.FindName('BtnDownTool').Add_Click({
            $saved = Invoke-ToolDownload $sel.Major $toolsDir
            if ($saved) { & $setStep2 $saved }
        })
    $dlg.FindName('BtnClose').Add_Click({ $dlg.Close() })
    if ($env:GUIDE_SHOT) {
        $root = $dlg.Content
        $sz = New-Object System.Windows.Size(680, 640)
        $root.Measure($sz); $root.Arrange((New-Object System.Windows.Rect(0, 0, 680, 640))); $root.UpdateLayout()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(680, 640, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [System.IO.File]::Create($env:GUIDE_SHOT); $enc.Save($fs); $fs.Close()
        return
    }
    $dlg.ShowDialog() | Out-Null
}

# 共享：按已选的版本直接下载对应官方制盘工具(不再二次选版本) → 返回保存路径(取消/失败返回 $null)
function Invoke-ToolDownload($PreferMajor, $toolsDir = $script:toolsDir) {
    $kind = if ($PreferMajor -eq 11) { 'Win11MCT' } else { 'Win10MCT' }
    $verName = "Windows $PreferMajor"
    $url = Get-OfficialToolUrl -Kind $kind
    $dest = Join-Path $toolsDir (Get-OfficialToolFileName -Kind $kind)

    # 先查文件夹：已经下过(非空)就直接用，不重复下载
    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -gt 0)) {
        $open = [System.Windows.MessageBox]::Show("检测到已经下载过了，不用重复下载：`n$dest`n`n这个工具在【本机】双击运行来做启动 U 盘/镜像。现在打开它所在文件夹吗？", '已有制盘工具', 'YesNo', 'Information')
        if ($open -eq 'Yes') { Start-Process explorer.exe "/select,`"$dest`"" }
        return $dest
    }

    $c = [System.Windows.MessageBox]::Show("本地还没有，将下载【$verName 官方制盘工具】(微软官方)。`n`n这个工具家庭版和专业版通用，装系统那一步再选具体版本。`n`n官方地址：`n$url`n`n现在开始下载吗？", '下载制盘工具', 'YesNo', 'Question')
    if ($c -ne 'Yes') { return $null }
    try {
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
        $saved = Save-OfficialTool -Kind $kind -OutDir $toolsDir
        [System.Windows.Input.Mouse]::OverrideCursor = $null
        $open = [System.Windows.MessageBox]::Show("下载完成！文件在：`n$saved`n`n注意：这个工具是在【本机】双击运行来制作启动 U 盘/镜像的(不是把它拷进 U 盘运行)。`n现在打开它所在文件夹吗？", '下载完成', 'YesNo', 'Information')
        if ($open -eq 'Yes') { Start-Process explorer.exe "/select,`"$saved`"" }
        return $saved
    }
    catch {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
        [System.Windows.MessageBox]::Show("$($_.Exception.Message)", '下载失败', 'OK', 'Warning')
        return $null
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="一键重装 + 桌面智能还原" Height="660" Width="940"
        WindowStartupLocation="CenterScreen" Background="#F5F7FA"
        FontFamily="Microsoft YaHei" FontSize="14">
  <Window.Resources>
    <Style x:Key="RoundBtn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="48"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="10" Padding="8,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.72"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#1E293B"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" CornerRadius="12" Padding="22,16" Margin="0,0,0,16">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#2563EB" Offset="0"/>
          <GradientStop Color="#4F46E5" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel>
        <TextBlock Text="一键重装 + 桌面智能还原" Foreground="White" FontSize="22" FontWeight="Bold"/>
        <TextBlock Text="装机前先【扫描】+【备份】桌面 → 【重装系统】(重置 / 选版本) → 装完【还原桌面】，可再按需【系统优化】。"
                   Foreground="#DBEAFE" FontSize="12.5" Margin="0,6,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>

    <UniformGrid Grid.Row="1" Columns="5" Margin="0,0,0,14">
      <Button x:Name="BtnScan"     Content="①  扫描桌面"  Style="{StaticResource RoundBtn}" Background="#2563EB" Margin="0,0,5,0"/>
      <Button x:Name="BtnBackup"   Content="②  备份选中"  Style="{StaticResource RoundBtn}" Background="#0891B2" Margin="3,0,5,0"/>
      <Button x:Name="BtnReset"    Content="③  重装系统"  Style="{StaticResource RoundBtn}" Background="#EA580C" Margin="5,0,5,0"/>
      <Button x:Name="BtnRestore"  Content="④  还原桌面"  Style="{StaticResource RoundBtn}" Background="#16A34A" Margin="5,0,5,0"/>
      <Button x:Name="BtnOptimize" Content="⑤  系统优化"  Style="{StaticResource RoundBtn}" Background="#7C3AED" Margin="5,0,0,0"/>
    </UniformGrid>

    <Border Grid.Row="2" Background="White" CornerRadius="12" BorderBrush="#E2E8F0" BorderThickness="1" Padding="6">
      <DataGrid x:Name="Grid" AutoGenerateColumns="False" CanUserAddRows="False"
                GridLinesVisibility="None" HeadersVisibility="Column" RowHeaderWidth="0"
                BorderThickness="0" Background="White" RowBackground="White"
                AlternatingRowBackground="#F1F5F9" RowHeight="34" FontSize="13"
                SelectionMode="Single">
        <DataGrid.Columns>
          <DataGridCheckBoxColumn Header="选" Binding="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Width="44"/>
          <DataGridTextColumn Header="名称" Binding="{Binding Name}" Width="200" IsReadOnly="True"/>
          <DataGridTextColumn Header="类型" Binding="{Binding Type}" Width="80" IsReadOnly="True"/>
          <DataGridTextColumn Header="本体盘" Binding="{Binding TargetDrive}" Width="70" IsReadOnly="True"/>
          <DataGridTextColumn Header="状态" Binding="{Binding Status}" Width="130" IsReadOnly="True"/>
          <DataGridTextColumn Header="目标路径" Binding="{Binding Target}" Width="*" IsReadOnly="True"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>

    <Border Grid.Row="3" Background="White" CornerRadius="8" BorderBrush="#E2E8F0" BorderThickness="1" Padding="12,8" Margin="0,12,0,0">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="●" Foreground="#16A34A" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="StatusBar" Text="就绪。" Foreground="#475569" FontSize="13" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)
$Grid = $win.FindName('Grid')
$BtnScan = $win.FindName('BtnScan')
$BtnBackup = $win.FindName('BtnBackup')
$BtnReset = $win.FindName('BtnReset')
$BtnRestore = $win.FindName('BtnRestore')
$BtnOptimize = $win.FindName('BtnOptimize')
$StatusBar = $win.FindName('StatusBar')

# ① 扫描桌面
$BtnScan.Add_Click({
        $items = Get-DesktopItems | ForEach-Object {
            $_ | Add-Member -NotePropertyName Selected -NotePropertyValue ($_.Status -ne 'needreinstall') -PassThru -Force
        }
        $coll = New-Object System.Collections.ObjectModel.ObservableCollection[object]
        foreach ($i in $items) { $coll.Add($i) }
        $Grid.ItemsSource = $coll
        $needReinstall = @($items | Where-Object { $_.Status -eq 'needreinstall' }).Count
        $StatusBar.Text = "已扫描 $($items.Count) 项；其中 $needReinstall 项本体在 C 盘(重装后需重装，已默认不勾)。请核对勾选后点【备份选中】。"
    })

# ② 备份选中
$BtnBackup.Add_Click({
        if (-not $Grid.ItemsSource) { [System.Windows.MessageBox]::Show('请先点【扫描桌面】。', '提示', 'OK', 'Information'); return }
        $items = @($Grid.ItemsSource)
        $sel = @($items | Where-Object { $_.Selected }).Count
        Invoke-DesktopBackup -Items $items -Destination $backupRoot | Out-Null
        $StatusBar.Text = "已备份 $sel 项到 $backupRoot （清单 manifest.json 已生成）。现在可以放心重装。"
    })

# ③ 重装系统：弹"重装方式"选择窗
$BtnReset.Add_Click({
        if (-not (Test-BackupReady -ManifestPath $manifest)) {
            [System.Windows.MessageBox]::Show('还没备份！请先完成【扫描桌面】+【备份选中】。', '阻止重装', 'OK', 'Warning'); return
        }
        $way = Show-ReinstallChoice
        if ($way -eq 'reset') {
            $curName = Get-CurrentWindowsName
            $c = [System.Windows.MessageBox]::Show("确认已完成备份，现在重置此电脑？`n`n• 会装回你当前的【$curName】，版本不变(不能换 Win10/换版次)。`n• 保留个人文件，但已装的软件会被清掉、设置恢复默认。`n• 备份位置：$backupRoot", '二次确认（不可逆）', 'YesNo', 'Warning')
            if ($c -eq 'Yes') { Invoke-SystemReset -ManifestPath $manifest -KeepFiles $true -Execute; $StatusBar.Text = "已唤起系统「重置此电脑」向导（装回 $curName）。" }
        }
        elseif ($way -eq 'image') {
            # 第一版菜单：Win11/Win10 × 家庭/专业，按"目标 vs 当前"自动分路
            $sel = Show-VersionPicker (Get-WindowsCatalog)
            if (-not $sel) { $StatusBar.Text = '就绪。'; return }
            $route = Get-ReinstallRoute -TargetMajor $sel.Major -TargetEdition $sel.Edition
            $cur = Get-CurrentWindowsMajor

            switch ($route) {
                'upgrade-exe' {
                    # 升级 + 家庭版：用官方"易升"exe 原地升级，保留文件
                    $c = [System.Windows.MessageBox]::Show(
                        "将用微软官方『易升』把系统原地升级到【$($sel.Title)】。`n`n这种方式会保留你的文件和软件，最省事。`n点【是】后我先下载官方工具(已有则直接用)，再启动它。", '升级确认', 'YesNo', 'Information')
                    if ($c -ne 'Yes') { $StatusBar.Text = '就绪。'; return }
                    try {
                        $StatusBar.Text = '正在准备官方易升工具(没有就联网下载，请稍候)…'
                        $exe = Save-OfficialTool -Kind 'Win11Assistant' -OutDir $toolsDir
                        Start-Process -FilePath $exe -ErrorAction Stop
                        $StatusBar.Text = "已启动官方易升，按向导继续即可，升级会保留你的文件。"
                    }
                    catch {
                        [System.Windows.MessageBox]::Show("$($_.Exception.Message)", '准备升级工具失败', 'OK', 'Warning')
                        $StatusBar.Text = '就绪。'
                    }
                }
                { $_ -in 'upgrade-iso', 'reinstall-iso' } {
                    # 专业版升级 / 同版本重装：优先用本地 ISO 的 setup.exe(原地升级保留文件)
                    $iso = Find-LocalIso -Major $sel.Major -Path $imagesDir
                    if ($iso) {
                        $c = [System.Windows.MessageBox]::Show(
                            "确认用本地镜像安装【$($sel.Title)】？`n`n来源：$([System.IO.Path]::GetFileName($iso))`n在安装向导里选『保留个人文件和应用』即为原地升级/重装。", '安装确认', 'YesNo', 'Warning')
                        if ($c -eq 'Yes') { Invoke-ImageInstall -IsoPath $iso -ManifestPath $manifest -Execute; $StatusBar.Text = "已启动【$($sel.Title)】安装向导，请在向导里继续。" }
                        else { $StatusBar.Text = '就绪。' }
                    }
                    else {
                        $c = [System.Windows.MessageBox]::Show(
                            "本地没有找到 Win$($sel.Major) 的 ISO 镜像。`n`n需要我帮你下载微软官方制盘工具吗？下完用它做一个 ISO/U 盘即可安装。", '没有本地镜像', 'YesNo', 'Question')
                        if ($c -ne 'Yes') { $StatusBar.Text = '就绪。'; return }
                        $saved = Invoke-ToolDownload $sel.Major $toolsDir
                        if ($saved) { $StatusBar.Text = "官方制盘工具已就绪：$saved。请用它做好镜像/U 盘后再回来安装。" }
                        else { $StatusBar.Text = '就绪。' }
                    }
                }
                'downgrade-usb' {
                    # 降级：系统内装不了，弹小白 U 盘引导(下载制盘工具的按钮就在引导窗里)
                    Show-DowngradeGuide $sel $toolsDir
                    $StatusBar.Text = "检测到降级(Win$cur→Win$($sel.Major))：已弹出 U 盘安装引导(可在窗内一键下载制盘工具)。"
                }
            }
        }
    })

# ④ 还原桌面（只还原，不动系统设置）
$BtnRestore.Add_Click({
        if (-not (Test-BackupReady -ManifestPath $manifest)) {
            [System.Windows.MessageBox]::Show('找不到备份清单，无法还原。', '提示', 'OK', 'Warning'); return
        }
        $rep = @(Invoke-DesktopRestore -Manifest $manifest)
        $ok = @($rep | Where-Object { $_.Restored }).Count
        $skip = @($rep | Where-Object { -not $_.Restored }).Count
        $StatusBar.Text = "已还原 $ok 项；$skip 项因桌面已存在而跳过(避免重复)。"
    })

# ⑤ 系统优化（独立按钮，点了才执行）
$BtnOptimize.Add_Click({
        $opt = @(Get-OptimizationItems)
        $names = ($opt | ForEach-Object { $_.Name }) -join '、'
        $c = [System.Windows.MessageBox]::Show("将应用以下优化：`n$names`n`n继续？", '系统优化', 'YesNo', 'Question')
        if ($c -eq 'Yes') {
            foreach ($o in $opt) { Invoke-Optimization -Id $o.Id }
            $StatusBar.Text = "已应用 $($opt.Count) 项系统优化：$names。"
        }
    })

# 自检模式（$env:UI_SELFTEST=1）：构建好窗口即退出，不弹窗，用于自动化烟测
if ($env:UI_SELFTEST) {
    if ($env:UI_SHOT) {
        $root = $win.Content
        $root.Background = [System.Windows.Media.Brushes]::WhiteSmoke
        $sz = New-Object System.Windows.Size(940, 660)
        $root.Measure($sz)
        $root.Arrange((New-Object System.Windows.Rect(0, 0, 940, 660)))
        $root.UpdateLayout()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(940, 660, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [System.IO.File]::Create($env:UI_SHOT)
        $enc.Save($fs); $fs.Close()
        Write-Host "SHOT_SAVED $env:UI_SHOT"
    }
    Write-Host 'UI_SELFTEST_OK：模块加载 + XAML 构建 + 事件绑定均成功。'
    return
}
$win.ShowDialog() | Out-Null
