#requires -version 5.1
<#
    Package Deployer Studio
    A desktop front-end for the Microsoft Package Deployer tool and the
    Power Platform CLI.

      Create Package  pac package init -> add-solution -> dotnet publish
      Deploy          clean -> load -> verify -> launch, or deploy via the CLI
      Environment     sign in, browse environments, select a target
      Solutions       list / export / import solutions in the selected environment

    Long operations run on a background runspace, so the window stays live and
    two actions can never overlap.

    Launch with PackageDeployerStudio.bat (needs -STA).
    MIT licensed.
#>

$ErrorActionPreference = 'Stop'
$script:AppVersion = '1.4.2'

# This app is WPF, which exists only on Windows. Say so plainly rather than
# letting Add-Type fail with an assembly-not-found error.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    $plat = if ($IsMacOS) { 'macOS' } else { 'Linux' }
    Write-Host ''
    Write-Host "  Package Deployer Studio is a Windows application." -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  You are on $plat. The user interface is built on WPF, which Microsoft"
    Write-Host "  ships for Windows only, and the Package Deployer tool it drives"
    Write-Host "  (PackageDeployer.exe) is a Windows application too."
    Write-Host ''
    Write-Host "  Use the cross-platform companion instead:" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "      ./install-mac.sh      then      pds"
    Write-Host ''
    Write-Host "  It covers sign-in, environments, solution export and import,"
    Write-Host "  building packages, and deploying by importing each solution in"
    Write-Host "  order. See the macOS section of README.md."
    Write-Host ''
    exit 1
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.IO.Compression.FileSystem

# Concrete CLR types. Binding a WPF ListView straight to PSCustomObject is
# unreliable; real classes always bind.
Add-Type -TypeDefinition @'
using System.ComponentModel;
public class EnvRow {
    public string Name { get; set; }
    public string Url  { get; set; }
    public string Id   { get; set; }
}
public class SolutionRow : INotifyPropertyChanged {
    private bool _sel;
    public bool Selected {
        get { return _sel; }
        set { _sel = value; if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs("Selected")); }
    }
    public string UniqueName   { get; set; }
    public string FriendlyName { get; set; }
    public string Version      { get; set; }
    public string Managed      { get; set; }
    public event PropertyChangedEventHandler PropertyChanged;
}
public class ActivityRow {
    public string Time    { get; set; }
    public string Level   { get; set; }
    public string Message { get; set; }
}
'@ -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Paths & state
# ---------------------------------------------------------------------------
$script:AppDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ToolDir      = Join-Path $script:AppDir 'PackageDeployertool'
$script:StateDir     = Join-Path $script:AppDir '.pdstudio'
$script:BaselineFile = Join-Path $script:StateDir 'tool-baseline.txt'
$script:SettingsFile = Join-Path $script:StateDir 'settings.json'
$script:LogDir       = Join-Path $script:AppDir 'logs'
$script:ExportDir    = Join-Path $script:AppDir 'exported-solutions'
# Where PackageDeployer.exe keeps its token cache, its last-connection config
# and its logs. Not the tool folder - that trips people up.
$script:DeployerProfileDir = Join-Path $env:APPDATA 'Microsoft\PackageDeployer'
# Used only by the "Check region" button, never automatically. Override it in
# .pdstudio\settings.json with "RegionUrl" to point at an internal endpoint.
$script:RegionUrl = 'https://ipinfo.io/json'

$script:ProtectedRegex = '^(Microsoft|System|Azure|Newtonsoft|SolutionPackagerLib|netstandard|PackageDeployer|pacTelemetryUpload|Windows|mscorlib|Presentation)'

$script:CurrentEnv    = $null
$script:LastBuilt     = $null
$script:LastBuiltDir  = $null
$script:Busy          = $false
$script:BusyTitle     = ''
$script:Job           = $null
$script:JobStarted    = $null
$script:Queue         = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
$script:RawLog        = New-Object System.Text.StringBuilder
$script:AllActivity   = New-Object 'System.Collections.Generic.List[ActivityRow]'
$script:BaselineCache = $null
$script:BaselineStamp = $null
$script:SidebarOpen   = $true
$script:LogOpen       = $true
$script:Theme         = 'Light'
$script:Draining      = $false

foreach ($d in @($script:StateDir, $script:LogDir, $script:ExportDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# Theme palettes. Every colour in the UI resolves to one of these keys, so a
# theme switch is just "walk the dictionary and change each brush's Color".
# ---------------------------------------------------------------------------
$script:Palettes = @{
    Light = @{
        WinBg='#FFF3F3F3'; Surface='#FFFFFFFF'; Surface2='#FFFAFAFA'; Field='#FFFCFCFC'
        Line='#FFE3E3E3';  Ink='#FF1B1B1B';     InkSoft='#FF5D5D5D';  NavIcon='#FF444444'
        Accent='#FF0F6CBD'; AccentSoft='#FFEFF6FC'; AccentInk='#FFFFFFFF'
        Danger='#FFC42B1C'; DangerSoft='#FFFDF3F2'
        Success='#FF0F7B0F'; SuccessSoft='#FFF1F8F1'
        Warn='#FF9D5D00';    WarnSoft='#FFFFF8E8'
        BtnBg='#FFFFFFFF';   BtnBorder='#FFCFCFCF'; Hover='#FFEDEDED'; Press='#FFDEDEDE'
        Scrim='#B0FFFFFF';   Mono='#FF3A3A3A';      Splitter='#FFE8E8E8'
    }
    Dark = @{
        WinBg='#FF1A1A1A'; Surface='#FF232323'; Surface2='#FF2A2A2A'; Field='#FF2E2E2E'
        Line='#FF3A3A3A';  Ink='#FFECECEC';     InkSoft='#FFA6A6A6';  NavIcon='#FFBFBFBF'
        Accent='#FF4CA0E0'; AccentSoft='#FF1E3448'; AccentInk='#FF10222F'
        Danger='#FFF07568'; DangerSoft='#FF3A2422'
        Success='#FF69C46A'; SuccessSoft='#FF1F3320'
        Warn='#FFE0A64B';    WarnSoft='#FF3A2F1B'
        BtnBg='#FF2E2E2E';   BtnBorder='#FF454545'; Hover='#FF383838'; Press='#FF454545'
        Scrim='#B01A1A1A';   Mono='#FFBFBFBF';      Splitter='#FF303030'
    }
}

# ---------------------------------------------------------------------------
# XAML
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Package Deployer Studio" Height="840" Width="1280"
        MinHeight="640" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">

  <Window.Resources>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="20"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13.5"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Foreground" Value="{DynamicResource InkSoft}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource InkSoft}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Setter Property="VerticalAlignment" Value="Bottom"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource Field}"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Ink}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,3,18,3"/>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,8"/>
      <Setter Property="MinWidth" Value="96"/>
      <Setter Property="MinHeight" Value="34"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="4"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsPressed"  Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.70"/></Trigger>
              <Trigger Property="IsEnabled"  Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource BtnBase}"/>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{DynamicResource Danger}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Danger}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
    </Style>
    <Style x:Key="BtnGo" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="{DynamicResource Success}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Success}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentInk}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnTiny" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Padding" Value="9,4"/><Setter Property="MinWidth" Value="0"/>
      <Setter Property="MinHeight" Value="0"/>
      <Setter Property="FontSize" Value="11"/><Setter Property="Margin" Value="0,0,6,0"/>
    </Style>
    <Style x:Key="BtnIcon" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="MinWidth" Value="0"/>
      <Setter Property="MinHeight" Value="0"/>
      <Setter Property="Padding" Value="7"/>
      <Setter Property="Margin" Value="0"/>
    </Style>

    <Style x:Key="CardBorder" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>

    <Style x:Key="NavList" TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox">
            <Border Background="Transparent" BorderThickness="0" Padding="0">
              <ScrollViewer Focusable="False" Background="Transparent"
                            HorizontalScrollBarVisibility="Disabled" VerticalScrollBarVisibility="Auto">
                <ItemsPresenter/>
              </ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavItem" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="5" Margin="8,2,8,2">
              <Grid>
                <Border x:Name="bar" Width="3" HorizontalAlignment="Left" Height="20"
                        CornerRadius="2" Background="Transparent"/>
                <ContentPresenter Margin="10,8,8,8"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource Hover}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource AccentSoft}"/>
                <Setter TargetName="bar" Property="Background" Value="{DynamicResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListView">
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Background" Value="{DynamicResource Surface2}"/>
      <Setter Property="Foreground" Value="{DynamicResource InkSoft}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
      <Setter Property="Background" Value="{DynamicResource Surface}"/>
      <Setter Property="Foreground" Value="{DynamicResource Ink}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <!-- Spinner: a full circular track with a rotating arc on top, so it reads
         as a complete ring instead of a lone arc chasing its tail. -->
    <Style x:Key="SpinTrack" TargetType="Ellipse">
      <Setter Property="Stroke" Value="{DynamicResource Line}"/>
      <Setter Property="StrokeThickness" Value="3"/>
      <Setter Property="Fill" Value="Transparent"/>
    </Style>
    <Style x:Key="SpinArc" TargetType="Path">
      <Setter Property="Stroke" Value="{DynamicResource Accent}"/>
      <Setter Property="StrokeThickness" Value="3"/>
      <Setter Property="StrokeStartLineCap" Value="Round"/>
      <Setter Property="StrokeEndLineCap" Value="Round"/>
      <Setter Property="Fill" Value="Transparent"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="RenderTransform">
        <Setter.Value><RotateTransform Angle="0"/></Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsVisible" Value="True">
          <Trigger.EnterActions>
            <BeginStoryboard Name="SpinSB">
              <Storyboard>
                <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(RotateTransform.Angle)"
                                 From="0" To="360" Duration="0:0:1" RepeatBehavior="Forever"/>
              </Storyboard>
            </BeginStoryboard>
          </Trigger.EnterActions>
          <Trigger.ExitActions><StopStoryboard BeginStoryboardName="SpinSB"/></Trigger.ExitActions>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="NavIconPath" TargetType="Path">
      <Setter Property="Stroke" Value="{DynamicResource NavIcon}"/>
      <Setter Property="StrokeThickness" Value="1.5"/>
      <Setter Property="Fill" Value="Transparent"/>
      <Setter Property="Width" Value="20"/><Setter Property="Height" Value="20"/>
      <Setter Property="Stretch" Value="Uniform"/>
      <Setter Property="StrokeLineJoin" Value="Round"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- activity row template -->
    <DataTemplate x:Key="ActivityTemplate">
      <Grid Margin="0,1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="62"/><ColumnDefinition Width="64"/><ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="{Binding Time}" FontSize="11"
                   Foreground="{DynamicResource InkSoft}" VerticalAlignment="Top" Margin="0,1,0,0"/>
        <Border   Grid.Column="1" x:Name="badge" CornerRadius="3" Padding="6,1" Margin="0,0,10,0"
                  HorizontalAlignment="Left" VerticalAlignment="Top"
                  Background="{DynamicResource Surface2}">
          <TextBlock x:Name="btxt" Text="{Binding Level}" FontSize="9.5" FontWeight="SemiBold"
                     Foreground="{DynamicResource InkSoft}"/>
        </Border>
        <TextBlock Grid.Column="2" x:Name="msg" Text="{Binding Message}" TextWrapping="Wrap"
                   FontSize="12" Foreground="{DynamicResource Ink}"/>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Level}" Value="OK">
          <Setter TargetName="badge" Property="Background" Value="{DynamicResource SuccessSoft}"/>
          <Setter TargetName="btxt"  Property="Foreground" Value="{DynamicResource Success}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="FAIL">
          <Setter TargetName="badge" Property="Background" Value="{DynamicResource DangerSoft}"/>
          <Setter TargetName="btxt"  Property="Foreground" Value="{DynamicResource Danger}"/>
          <Setter TargetName="msg"   Property="Foreground" Value="{DynamicResource Danger}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="WARN">
          <Setter TargetName="badge" Property="Background" Value="{DynamicResource WarnSoft}"/>
          <Setter TargetName="btxt"  Property="Foreground" Value="{DynamicResource Warn}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="CMD">
          <Setter TargetName="badge" Property="Background" Value="{DynamicResource AccentSoft}"/>
          <Setter TargetName="btxt"  Property="Foreground" Value="{DynamicResource Accent}"/>
          <Setter TargetName="msg"   Property="FontFamily" Value="Consolas"/>
          <Setter TargetName="msg"   Property="Foreground" Value="{DynamicResource Accent}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="OUT">
          <Setter TargetName="badge" Property="Background" Value="Transparent"/>
          <Setter TargetName="btxt"  Property="Text" Value=""/>
          <Setter TargetName="msg"   Property="FontFamily" Value="Consolas"/>
          <Setter TargetName="msg"   Property="FontSize" Value="11"/>
          <Setter TargetName="msg"   Property="Foreground" Value="{DynamicResource Mono}"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Level}" Value="STEP">
          <Setter TargetName="badge" Property="Background" Value="Transparent"/>
          <Setter TargetName="btxt"  Property="Text" Value=""/>
          <Setter TargetName="msg"   Property="FontWeight" Value="SemiBold"/>
          <Setter TargetName="msg"   Property="FontSize" Value="12.5"/>
          <Setter TargetName="msg"   Property="Foreground" Value="{DynamicResource Accent}"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition x:Name="ColSidebar" Width="232"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ================= SIDEBAR ================= -->
    <Border Grid.Column="0" x:Name="Sidebar" Background="{DynamicResource Surface}"
            BorderBrush="{DynamicResource Line}" BorderThickness="0,0,1,0">
      <DockPanel>

        <Grid DockPanel.Dock="Top" Margin="10,14,10,10">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Button Grid.Column="0" x:Name="BtnBurger" Style="{StaticResource BtnIcon}" ToolTip="Collapse or expand the sidebar">
            <Path Style="{StaticResource NavIconPath}" Width="18" Height="18"
                  Data="M2,4 L18,4 M2,10 L18,10 M2,16 L18,16"/>
          </Button>
          <StackPanel Grid.Column="1" x:Name="BrandBox" Margin="6,0,0,0" VerticalAlignment="Center">
            <TextBlock x:Name="TbBrand" Text="Package Deployer Studio" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock x:Name="TbVersion" Style="{StaticResource Hint}" Margin="0,1,0,0"/>
          </StackPanel>
        </Grid>

        <Border DockPanel.Dock="Bottom" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="14,10">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Ellipse Grid.Column="0" x:Name="EnvDot" Width="9" Height="9" Fill="{DynamicResource Danger}"
                     VerticalAlignment="Center" ToolTip="Connection state"/>
            <StackPanel Grid.Column="1" x:Name="EnvBox" Margin="9,0,0,0">
              <TextBlock Text="CONNECTED TO" FontSize="9" Foreground="{DynamicResource InkSoft}" FontWeight="SemiBold"/>
              <TextBlock x:Name="TbEnvChip" Text="Not connected" FontSize="11.5" TextWrapping="Wrap"
                         Foreground="{DynamicResource Danger}" Margin="0,2,0,0"/>
            </StackPanel>
          </Grid>
        </Border>

        <ListBox x:Name="Nav" Style="{StaticResource NavList}"
                 ItemContainerStyle="{StaticResource NavItem}" Margin="0,4,0,0">
          <ListBoxItem ToolTip="Create Package">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Path Grid.Column="0" Style="{StaticResource NavIconPath}"
                    Data="M10,2 L18,6.2 L10,10.4 L2,6.2 Z M2,6.2 L2,14.2 L10,18.4 L10,10.4 M18,6.2 L18,14.2 L10,18.4"/>
              <TextBlock Grid.Column="1" x:Name="NavLbl0" Text="Create Package" FontSize="13" Margin="8,0,0,0"/>
            </Grid>
          </ListBoxItem>
          <ListBoxItem ToolTip="Deploy">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Path Grid.Column="0" Style="{StaticResource NavIconPath}"
                    Data="M10,2 L10,12 M6,6 L10,2 L14,6 M3,13 L3,17 L17,17 L17,13"/>
              <TextBlock Grid.Column="1" x:Name="NavLbl1" Text="Deploy" FontSize="13" Margin="8,0,0,0"/>
            </Grid>
          </ListBoxItem>
          <ListBoxItem ToolTip="Environment">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Path Grid.Column="0" Style="{StaticResource NavIconPath}"
                    Data="M10,2 A8,8 0 1,0 10,18 A8,8 0 1,0 10,2 Z M2,10 L18,10 M10,2 A11,11 0 0,1 10,18 M10,2 A11,11 0 0,0 10,18"/>
              <TextBlock Grid.Column="1" x:Name="NavLbl2" Text="Environment" FontSize="13" Margin="8,0,0,0"/>
            </Grid>
          </ListBoxItem>
          <ListBoxItem ToolTip="Solutions">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Path Grid.Column="0" Style="{StaticResource NavIconPath}"
                    Data="M3,4 L17,4 L17,8 L3,8 Z M3,12 L17,12 L17,16 L3,16 Z"/>
              <TextBlock Grid.Column="1" x:Name="NavLbl3" Text="Solutions" FontSize="13" Margin="8,0,0,0"/>
            </Grid>
          </ListBoxItem>
        </ListBox>
      </DockPanel>
    </Border>

    <!-- ================= CONTENT ================= -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition x:Name="RowLog" Height="240"/>
      </Grid.RowDefinitions>

      <!-- header -->
      <Border Grid.Row="0" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Line}"
              BorderThickness="0,0,0,1" Padding="24,14">
        <DockPanel>
          <StackPanel DockPanel.Dock="Left">
            <TextBlock x:Name="TbPageTitle" Text="Create Package" Style="{StaticResource H1}"/>
            <TextBlock x:Name="TbPageSub" Style="{StaticResource Hint}" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="BtnTheme" Style="{StaticResource BtnTiny}" MinWidth="96" ToolTip="Switch between light and dark">
              <StackPanel Orientation="Horizontal">
                <Path x:Name="IcTheme" Style="{StaticResource NavIconPath}" Width="14" Height="14"
                      Data="M10,3 A7,7 0 1,0 17,10 A5.5,5.5 0 0,1 10,3 Z"/>
                <TextBlock x:Name="TbTheme" Text="Dark" FontSize="11.5" Margin="7,0,0,0"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </DockPanel>
      </Border>

      <ProgressBar x:Name="PbTop" Grid.Row="0" Height="3" VerticalAlignment="Bottom" IsIndeterminate="True" Minimum="0" Maximum="100"
                   BorderThickness="0" Visibility="Collapsed" Panel.ZIndex="10"
                   Foreground="{DynamicResource Accent}" Background="Transparent"/>

      <!-- pages -->
      <Grid Grid.Row="1">

        <!-- PAGE 0: CREATE PACKAGE -->
        <ScrollViewer x:Name="PageCreate" VerticalScrollBarVisibility="Auto" Padding="24,18,24,18">
          <StackPanel>
            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Package project" Style="{StaticResource H2}"/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Margin="0,0,16,0">
                    <TextBlock Text="Package name" Style="{StaticResource Label}"/>
                    <TextBox x:Name="TxtPkgName" Text="DeploymentPackage"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" Margin="0,0,8,0">
                    <TextBlock Text="Output folder" Style="{StaticResource Label}"/>
                    <TextBox x:Name="TxtOutDir"/>
                  </StackPanel>
                  <Button Grid.Column="2" x:Name="BtnOutBrowse" Content="Browse..." VerticalAlignment="Bottom" Margin="0,0,0,2"/>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Solutions to include" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10"
                           Text="Import order runs top to bottom. Exports from the Solutions page land here automatically."/>
                <Grid Height="210">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <ListBox Grid.Column="0" x:Name="LstSolutions" Margin="0,0,10,0"/>
                  <StackPanel Grid.Column="1" Width="126">
                    <Button x:Name="BtnSolAdd"   Content="Add zips"/>
                    <Button x:Name="BtnSolUp"    Content="Move up"/>
                    <Button x:Name="BtnSolDown"  Content="Move down"/>
                    <Button x:Name="BtnSolDel"   Content="Remove"/>
                    <Button x:Name="BtnSolClear" Content="Clear all" Style="{StaticResource BtnDanger}"/>
                  </StackPanel>
                </Grid>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Build" Style="{StaticResource H2}"/>
                <WrapPanel>
                  <Button x:Name="BtnBuild"       Content="Create package" Style="{StaticResource BtnGo}" MinWidth="150"/>
                  <Button x:Name="BtnOpenOut"     Content="Open output folder"/>
                  <Button x:Name="BtnUseInDeploy" Content="Send to Deploy"/>
                </WrapPanel>
                <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0"
                           Text="Runs pac package init, then pac package add-solution per entry, then dotnet publish. Needs the PAC CLI and .NET SDK on PATH."/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE 1: DEPLOY -->
        <ScrollViewer x:Name="PageDeploy" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,18,24,18">
          <StackPanel>
            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Deploy with the Package Deployer GUI tool" Style="{StaticResource H2}"/>
                <Border x:Name="BdNoTool" Background="{DynamicResource WarnSoft}" BorderBrush="{DynamicResource Warn}"
                        BorderThickness="1" CornerRadius="4" Padding="12,10" Margin="0,0,0,12" Visibility="Collapsed">
                  <StackPanel>
                    <TextBlock Text="Microsoft's Package Deployer tool was not found" FontWeight="SemiBold" FontSize="12"
                               Foreground="{DynamicResource Warn}" Margin="0,0,0,4"/>
                    <TextBlock Style="{StaticResource Hint}" Foreground="{DynamicResource Warn}"
                               Text="Only the four steps below need it. Deploying with the PAC CLI above works without it. Click Browse and pick the folder that contains PackageDeployer.exe."/>
                  </StackPanel>
                </Border>

                <TextBlock Text="Tool folder" Style="{StaticResource Label}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,7"
                           Text="The folder containing PackageDeployer.exe. Configured for you at install time when it can be found."/>
                <Grid Margin="0,0,0,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox Grid.Column="0" x:Name="TxtTool" Margin="0,0,8,0"/>
                  <Button  Grid.Column="1" x:Name="BtnToolBrowse" Content="Browse..." Margin="0,0,8,0"/>
                  <Button  Grid.Column="2" x:Name="BtnBaseline"   Content="Snapshot" Margin="0"
                           ToolTip="Records which files ship with the tool, so Clean knows exactly which files are yours."/>
                </Grid>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12"
                           Text="Snapshot: click once while no package is loaded. It writes down the 550-odd files that come with the tool, so Clean can remove your package precisely instead of guessing from file names. Optional - Clean falls back to name rules without it, but the snapshot is safer."/>

                <TextBlock Text="Package to load into the tool" Style="{StaticResource Label}"/>
                <Border Background="{DynamicResource Surface2}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                        CornerRadius="4" Padding="11,9" Margin="0,0,0,9">
                  <StackPanel>
                    <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,5"
                               Text="Zip or folder, both fine. The folder is the one holding the package .dll next to its PkgAssets folder."/>
                    <TextBlock Style="{StaticResource Hint}" FontFamily="Consolas" Margin="0,0,0,2"
                               Text="Zip     C:\Research\TestPackage\DeploymentPackage\bin\Debug\DeploymentPackage.1.0.0.pdpkg.zip"/>
                    <TextBlock Style="{StaticResource Hint}" FontFamily="Consolas"
                               Text="Folder  C:\Research\TestPackage\DeploymentPackage\bin\Debug\net472\pdpublish"/>
                  </StackPanel>
                </Border>
                <Grid Margin="0,0,0,14">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox Grid.Column="0" x:Name="TxtPkg" Margin="0,0,8,0"/>
                  <Button  Grid.Column="1" x:Name="BtnPkgFolder" Content="Folder..." ToolTip="Pick the publish folder that contains the package assembly and its assets folder" Margin="0,0,8,0"/>
                  <Button  Grid.Column="2" x:Name="BtnPkgZip"    Content="Zip..." ToolTip="Pick the .pdpkg.zip your build produced"    Margin="0"/>
                </Grid>

                <Border Background="{DynamicResource Surface2}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                        CornerRadius="4" Padding="12" Margin="0,0,0,14">
                  <StackPanel>
                    <TextBlock Text="Tool folder state" FontWeight="SemiBold" FontSize="12" Margin="0,0,0,6"/>
                    <TextBlock x:Name="TbState" Text="Not checked yet." Style="{StaticResource Hint}" FontFamily="Consolas"/>
                  </StackPanel>
                </Border>

                <WrapPanel>
                  <Button x:Name="BtnClean"  Content="1. Clean"  Style="{StaticResource BtnDanger}"/>
                  <Button x:Name="BtnLoad"   Content="2. Load"/>
                  <Button x:Name="BtnVerify" Content="3. Verify"/>
                  <Button x:Name="BtnLaunch" Content="4. Launch" Style="{StaticResource BtnPrimary}"/>
                  <Button x:Name="BtnAll"    Content="Do all 1-4" Style="{StaticResource BtnGo}" Margin="18,0,8,8"/>
                </WrapPanel>
                <WrapPanel>
                  <CheckBox x:Name="ChkTokens"     Content="Forget the sign-in when cleaning" IsChecked="True"
                            ToolTip="Clears the cached account and the remembered environment, so the tool asks again."/>
                  <CheckBox x:Name="ChkAutoLaunch" Content="Launch after 'Do all'"/>
                </WrapPanel>

                <Border Background="{DynamicResource Surface2}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                        CornerRadius="4" Padding="12,10" Margin="0,12,0,0">
                  <StackPanel>
                    <TextBlock Text="Deploying again as a different account?" FontWeight="SemiBold" FontSize="12" Margin="0,0,0,4"/>
                    <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,9"
                               Text="Package Deployer caches your sign-in and the environment you picked, so a second run goes straight through without asking. Clear it and it will prompt again."/>
                    <WrapPanel>
                      <Button x:Name="BtnForget"      Content="Forget sign-in" Style="{StaticResource BtnPrimary}"/>
                      <Button x:Name="BtnOpenPdCache" Content="Open cache folder"/>
                    </WrapPanel>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Or deploy straight from the command line" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10"
                           Text="Deploys to the environment shown in the sidebar, after confirming the target."/>
                <TextBlock Text="Package to deploy" Style="{StaticResource Label}"/>
                <Border Background="{DynamicResource Surface2}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                        CornerRadius="4" Padding="11,9" Margin="0,0,0,9">
                  <StackPanel>
                    <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,5"
                               Text="Yes - a .pdpkg.zip is exactly what goes here. pac package deploy takes a package zip or the package .dll."/>
                    <TextBlock Style="{StaticResource Hint}" FontFamily="Consolas" Margin="0,0,0,2"
                               Text="Zip     C:\Research\TestPackage\DeploymentPackage\bin\Debug\DeploymentPackage.1.0.0.pdpkg.zip"/>
                    <TextBlock Style="{StaticResource Hint}" FontFamily="Consolas"
                               Text="Folder  C:\Research\TestPackage\DeploymentPackage\bin\Debug\net472\pdpublish"/>
                    <TextBlock Style="{StaticResource Hint}" Margin="0,5,0,0"
                               Text="Pick a folder and the zip or .dll inside it is found for you."/>
                  </StackPanel>
                </Border>
                <Grid Margin="0,0,0,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox Grid.Column="0" x:Name="TxtDeployPkg" Margin="0,0,8,0"/>
                  <Button  Grid.Column="1" x:Name="BtnDeployZip"    Content="Zip..." ToolTip="Pick the .pdpkg.zip your build produced"    Margin="0,0,8,0"/>
                  <Button  Grid.Column="2" x:Name="BtnDeployFolder" Content="Folder..." ToolTip="Pick the publish folder that contains the package assembly and its assets folder" Margin="0"/>
                </Grid>
                <WrapPanel>
                  <Button x:Name="BtnCliDeploy"  Content="Deploy package" Style="{StaticResource BtnGo}" MinWidth="150"/>
                  <Button x:Name="BtnDeployLogs" Content="Open deploy logs"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE 2: ENVIRONMENT -->
        <ScrollViewer x:Name="PageEnv" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,18,24,18">
          <StackPanel>
            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="1. Sign in" Style="{StaticResource H2}"/>
                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12"
                           Text="Opens a console window and the Microsoft sign-in page. Complete sign-in there, including MFA, then come back."/>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="240"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Margin="0,0,16,0">
                    <TextBlock Text="Name this connection" Style="{StaticResource Label}"/>
                    <TextBox x:Name="TxtAuthName" Text="DevEnv"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" VerticalAlignment="Bottom">
                    <CheckBox x:Name="ChkDeviceCode" Content="Use device code instead"
                              ToolTip="Shows a code to type at microsoft.com/devicelogin. Use if the browser popup never appears."/>
                  </StackPanel>
                </Grid>
                <WrapPanel Margin="0,14,0,0">
                  <Button x:Name="BtnSignIn"     Content="Sign in" Style="{StaticResource BtnPrimary}"/>
                  <Button x:Name="BtnAuthList"   Content="Saved connections"/>
                  <Button x:Name="BtnAuthSelect" Content="Switch to named"/>
                  <Button x:Name="BtnSignOut"    Content="Clear all" Style="{StaticResource BtnDanger}"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <DockPanel Margin="0,0,0,10">
                  <TextBlock Text="2. Choose an environment" Style="{StaticResource H2}" DockPanel.Dock="Left" Margin="0"/>
                  <WrapPanel HorizontalAlignment="Right">
                    <Button x:Name="BtnEnvRefresh" Content="Load environments" Style="{StaticResource BtnTiny}"/>
                    <Button x:Name="BtnWhoAmI"     Content="Who am I?"         Style="{StaticResource BtnTiny}"/>
                  </WrapPanel>
                </DockPanel>
                <ListView x:Name="LvEnvs" Height="240">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Header="Environment" Width="320" DisplayMemberBinding="{Binding Name}"/>
                      <GridViewColumn Header="URL"         Width="360" DisplayMemberBinding="{Binding Url}"/>
                      <GridViewColumn Header="ID"          Width="250" DisplayMemberBinding="{Binding Id}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <WrapPanel Margin="0,12,0,0">
                  <Button x:Name="BtnEnvSelect" Content="Use selected environment" Style="{StaticResource BtnPrimary}" MinWidth="180"/>
                  <TextBlock x:Name="TbEnvCount" Style="{StaticResource Hint}" Margin="8,0,0,0"/>
                </WrapPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- PAGE 3: SOLUTIONS -->
        <ScrollViewer x:Name="PageSol" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="24,18,24,18">
          <StackPanel>
            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <DockPanel Margin="0,0,0,10">
                  <TextBlock Text="Solutions in the selected environment" Style="{StaticResource H2}" DockPanel.Dock="Left" Margin="0"/>
                  <WrapPanel HorizontalAlignment="Right">
                    <CheckBox x:Name="ChkSysSolutions" Content="Include system solutions" Margin="0,0,10,0"/>
                    <Button x:Name="BtnSolRefresh" Content="Load solutions" Style="{StaticResource BtnTiny}"/>
                  </WrapPanel>
                </DockPanel>
                <ListView x:Name="LvSols" Height="300">
                  <ListView.View>
                    <GridView>
                      <GridViewColumn Width="38">
                        <GridViewColumn.CellTemplate>
                          <DataTemplate>
                            <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" Margin="0"/>
                          </DataTemplate>
                        </GridViewColumn.CellTemplate>
                      </GridViewColumn>
                      <GridViewColumn Header="Display name" Width="290" DisplayMemberBinding="{Binding FriendlyName}"/>
                      <GridViewColumn Header="Unique name"  Width="250" DisplayMemberBinding="{Binding UniqueName}"/>
                      <GridViewColumn Header="Version"      Width="110" DisplayMemberBinding="{Binding Version}"/>
                      <GridViewColumn Header="Managed"      Width="80"  DisplayMemberBinding="{Binding Managed}"/>
                    </GridView>
                  </ListView.View>
                </ListView>
                <WrapPanel Margin="0,10,0,0">
                  <Button x:Name="BtnSolAll"  Content="Select all"  Style="{StaticResource BtnTiny}"/>
                  <Button x:Name="BtnSolNone" Content="Select none" Style="{StaticResource BtnTiny}"/>
                  <TextBlock x:Name="TbSolCount" Style="{StaticResource Hint}" Margin="8,0,0,0"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Export checked solutions" Style="{StaticResource H2}"/>
                <TextBlock Text="Export folder" Style="{StaticResource Label}"/>
                <Grid Margin="0,0,0,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox Grid.Column="0" x:Name="TxtExportDir" Margin="0,0,8,0"/>
                  <Button  Grid.Column="1" x:Name="BtnExportDir" Content="Browse" Margin="0"/>
                </Grid>
                <WrapPanel Margin="0,0,0,10">
                  <CheckBox x:Name="ChkExpManaged"   Content="Managed" IsChecked="True"/>
                  <CheckBox x:Name="ChkExpUnmanaged" Content="Unmanaged"/>
                  <CheckBox x:Name="ChkExpToPackage" Content="Add exports to the Create Package list" IsChecked="True"/>
                </WrapPanel>
                <WrapPanel>
                  <Button x:Name="BtnExport"     Content="Export checked" Style="{StaticResource BtnPrimary}" MinWidth="150"/>
                  <Button x:Name="BtnOpenExport" Content="Open export folder"/>
                </WrapPanel>
              </StackPanel>
            </Border>

            <Border Style="{StaticResource CardBorder}">
              <StackPanel>
                <TextBlock Text="Import a solution into the selected environment" Style="{StaticResource H2}"/>
                <Grid Margin="0,0,0,12">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox Grid.Column="0" x:Name="TxtImportZip" Margin="0,0,8,0"/>
                  <Button  Grid.Column="1" x:Name="BtnImportPick" Content="Choose zip" Margin="0"/>
                </Grid>
                <WrapPanel Margin="0,0,0,10">
                  <CheckBox x:Name="ChkImpPublish"  Content="Publish changes" IsChecked="True"/>
                  <CheckBox x:Name="ChkImpActivate" Content="Activate plug-ins" IsChecked="True"/>
                  <CheckBox x:Name="ChkImpForce"    Content="Force overwrite unmanaged customizations"/>
                  <CheckBox x:Name="ChkImpUpgrade"  Content="Stage and upgrade"/>
                </WrapPanel>
                <Button x:Name="BtnImport" Content="Import solution" Style="{StaticResource BtnGo}" MinWidth="150"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- busy overlay, covers the page area only so the activity log stays readable -->
        <Border x:Name="Overlay" Background="{DynamicResource Scrim}" Visibility="Collapsed">
          <Border Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                  CornerRadius="10" Padding="24,20" Width="420"
                  HorizontalAlignment="Center" VerticalAlignment="Center">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid Grid.Column="0" Width="30" Height="30" VerticalAlignment="Top" Margin="0,2,16,0">
                <Ellipse Style="{StaticResource SpinTrack}" Width="30" Height="30"/>
                <Path x:Name="IcSpinner" Style="{StaticResource SpinArc}"
                      Data="M 15,1.5 A 13.5,13.5 0 0 1 28.5,15"/>
              </Grid>
              <StackPanel Grid.Column="1">
                <DockPanel>
                  <TextBlock x:Name="TbOverlayPct" DockPanel.Dock="Right" Text="" FontSize="12.5" FontWeight="SemiBold"
                             Foreground="{DynamicResource Accent}" VerticalAlignment="Top" Margin="8,1,0,0"/>
                  <TextBlock x:Name="TbOverlayTitle" Text="Working..." FontSize="14.5" FontWeight="SemiBold" TextWrapping="Wrap"/>
                </DockPanel>
                <TextBlock x:Name="TbOverlaySub" Style="{StaticResource Hint}" Margin="0,5,0,12"
                           Text="Progress appears in the activity log below."/>
                <ProgressBar x:Name="PbBusy" Height="5" IsIndeterminate="True" Minimum="0" Maximum="100" BorderThickness="0"
                             Foreground="{DynamicResource Accent}" Background="{DynamicResource Surface2}"/>
              </StackPanel>
            </Grid>
          </Border>
        </Border>
      </Grid>

      <!-- activity panel -->
      <GridSplitter Grid.Row="2" Height="5" HorizontalAlignment="Stretch" Background="{DynamicResource Splitter}"
                    VerticalAlignment="Center" ResizeBehavior="PreviousAndNext"/>
      <Border Grid.Row="3" Background="{DynamicResource Surface}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0">
        <Grid Margin="24,10,24,14">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Grid.Row="0" Margin="0,0,0,8">
            <Button x:Name="BtnLogToggle" Style="{StaticResource BtnIcon}" DockPanel.Dock="Left" ToolTip="Show or hide the activity log">
              <Path x:Name="IcLogChevron" Style="{StaticResource NavIconPath}" Width="14" Height="14" Data="M4,12 L10,6 L16,12"/>
            </Button>
            <TextBlock Text="Activity" FontWeight="SemiBold" FontSize="12.5" DockPanel.Dock="Left" Margin="6,0,14,0"/>
            <Grid x:Name="IcMiniSpin" Width="14" Height="14" DockPanel.Dock="Left" Margin="0,0,8,0"
                  Visibility="Collapsed" VerticalAlignment="Center">
              <Ellipse Style="{StaticResource SpinTrack}" StrokeThickness="2" Width="14" Height="14"/>
              <Path Style="{StaticResource SpinArc}" StrokeThickness="2" Data="M 7,1 A 6,6 0 0 1 13,7"/>
            </Grid>
            <TextBlock x:Name="TbLastStatus" Style="{StaticResource Hint}" DockPanel.Dock="Left"/>
            <WrapPanel HorizontalAlignment="Right">
              <ComboBox x:Name="CmbFilter" Width="132" Margin="0,0,8,0" SelectedIndex="0">
                <ComboBoxItem Content="Everything"/>
                <ComboBoxItem Content="Steps and results"/>
                <ComboBoxItem Content="Problems only"/>
              </ComboBox>
              <Button x:Name="BtnSelfTest" Content="Self-test"     Style="{StaticResource BtnTiny}"/>
              <Button x:Name="BtnRegion"   Content="Check region" Style="{StaticResource BtnTiny}"
                      ToolTip="Look up the public IP and location your traffic leaves from. Confirms the VPN is actually carrying it."/>
              <Button x:Name="BtnOpenLogs" Content="Deployer logs" Style="{StaticResource BtnTiny}"/>
              <Button x:Name="BtnSaveLog"  Content="Save"          Style="{StaticResource BtnTiny}"/>
              <Button x:Name="BtnClearLog" Content="Clear"         Style="{StaticResource BtnTiny}"/>
            </WrapPanel>
          </DockPanel>
          <Border Grid.Row="1" x:Name="LogHost" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="4">
            <ListView x:Name="LvLog" BorderThickness="0" Background="{DynamicResource Surface2}"
                      ItemTemplate="{StaticResource ActivityTemplate}"
                      ScrollViewer.HorizontalScrollBarVisibility="Disabled">
              <ListView.ItemContainerStyle>
                <Style TargetType="ListViewItem">
                  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                  <Setter Property="Padding" Value="8,2"/>
                  <Setter Property="BorderThickness" Value="0"/>
                </Style>
              </ListView.ItemContainerStyle>
            </ListView>
          </Border>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
# Build window
#
# Theming works by swapping a whole merged ResourceDictionary, which is the
# canonical WPF approach and avoids two traps that both bit earlier versions:
#
#   1. Brushes loaded from XAML are FROZEN, so "$brush.Color = ..." throws
#      "Cannot set a property ... because it is in a read-only state."
#   2. Assigning a PowerShell-built brush into ResourceDictionary's
#      object-typed indexer stores the PSObject *wrapper*, not the brush.
#      WPF then rejects it with "'#FFFAFAFA' is not a valid value for
#      property 'Background'" - that string is the wrapper's ToString().
#
# Building each palette with XamlReader.Parse keeps PowerShell object
# marshalling out of the picture completely: the dictionary and everything in
# it are created by WPF itself.
# ---------------------------------------------------------------------------
function New-ThemeDictionary {
    param([hashtable]$Palette)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">')
    foreach ($k in ($Palette.Keys | Sort-Object)) {
        [void]$sb.AppendLine(('  <SolidColorBrush x:Key="{0}" Color="{1}"/>' -f $k, $Palette[$k]))
    }
    [void]$sb.AppendLine('</ResourceDictionary>')
    return [System.Windows.ResourceDictionary]([Windows.Markup.XamlReader]::Parse($sb.ToString()))
}

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win    = [Windows.Markup.XamlReader]::Load($reader)

# Every colour in the markup is a DynamicResource, so it resolves lazily - the
# palette only has to be present before the first render, not before parsing.
$script:ThemeDicts = @{}
foreach ($t in @('Light','Dark')) { $script:ThemeDicts[$t] = New-ThemeDictionary $script:Palettes[$t] }
$win.Resources.MergedDictionaries.Add($script:ThemeDicts['Light'])

# Attributes on the root tag are parsed before Window.Resources exists, so the
# window background is bound here instead of in the markup.
$win.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'WinBg')

$ctl = @{}
foreach ($n in @(
    'ColSidebar','Sidebar','BtnBurger','BrandBox','TbBrand','TbVersion','EnvDot','EnvBox','TbEnvChip',
    'Nav','NavLbl0','NavLbl1','NavLbl2','NavLbl3',
    'TbPageTitle','TbPageSub','BtnTheme','IcTheme','TbTheme',
    'PageCreate','PageDeploy','PageEnv','PageSol','Overlay','TbOverlayTitle','TbOverlaySub','PbBusy',
    'IcSpinner','PbTop','IcMiniSpin','BdNoTool','TbOverlayPct',
    'TxtPkgName','TxtOutDir','BtnOutBrowse','LstSolutions','BtnSolAdd','BtnSolUp','BtnSolDown','BtnSolDel',
    'BtnSolClear','BtnBuild','BtnOpenOut','BtnUseInDeploy',
    'TxtDeployPkg','BtnDeployZip','BtnDeployFolder','BtnCliDeploy','BtnDeployLogs',
    'TxtTool','BtnToolBrowse','BtnBaseline','TxtPkg','BtnPkgFolder','BtnPkgZip','TbState',
    'BtnClean','BtnLoad','BtnVerify','BtnLaunch','BtnAll','ChkTokens','ChkAutoLaunch',
    'BtnForget','BtnOpenPdCache',
    'TxtAuthName','ChkDeviceCode','BtnSignIn','BtnAuthList','BtnAuthSelect','BtnSignOut',
    'BtnEnvRefresh','BtnWhoAmI','LvEnvs','BtnEnvSelect','TbEnvCount',
    'ChkSysSolutions','BtnSolRefresh','LvSols','BtnSolAll','BtnSolNone','TbSolCount',
    'TxtExportDir','BtnExportDir','ChkExpManaged','ChkExpUnmanaged','ChkExpToPackage','BtnExport','BtnOpenExport',
    'TxtImportZip','BtnImportPick','ChkImpPublish','ChkImpActivate','ChkImpForce','ChkImpUpgrade','BtnImport',
    'RowLog','BtnLogToggle','IcLogChevron','TbLastStatus','CmbFilter','LvLog','LogHost',
    'BtnSelfTest','BtnRegion','BtnOpenLogs','BtnSaveLog','BtnClearLog')) {
    $ctl[$n] = $win.FindName($n)
}

$script:View = New-Object 'System.Collections.ObjectModel.ObservableCollection[ActivityRow]'
$ctl.LvLog.ItemsSource = $script:View

# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------
function Set-Theme {
    param([ValidateSet('Light','Dark')][string]$Name)
    # Swap the palette dictionary IN PLACE. Clear() followed by Add() leaves a
    # moment where the keys do not exist, and any control that re-evaluates in
    # that window falls back to its Windows default - which is why the sidebar
    # flipped to white. Assigning by index is atomic, so there is no gap.
    $md = $win.Resources.MergedDictionaries
    if ($md.Count -eq 0) { $md.Add($script:ThemeDicts[$Name]) }
    else                 { $md[0] = $script:ThemeDicts[$Name] }
    $script:Theme = $Name

    # Assign the chrome brushes DIRECTLY rather than trusting the dynamic
    # lookup. The sidebar kept rendering with the light palette even though its
    # markup asks for {DynamicResource Surface} and everything around it
    # updated; a direct set on a Brush-typed property is deterministic, and
    # takes precedence over the dynamic reference. The brushes come straight
    # out of the theme dictionary, so they are WPF-created and already frozen.
    $td = $script:ThemeDicts[$Name]
    $ctl.Sidebar.Background  = $td['Surface']
    $ctl.Sidebar.BorderBrush = $td['Line']
    $ctl.Nav.Foreground      = $td['Ink']
    $win.Background          = $td['WinBg']
    $ctl.TbTheme.Text = if ($Name -eq 'Light') { 'Dark' } else { 'Light' }
    # sun when dark is active, crescent moon when light is active
    $ctl.IcTheme.Data = if ($Name -eq 'Light') {
        [System.Windows.Media.Geometry]::Parse('M10,3 A7,7 0 1,0 17,10 A5.5,5.5 0 0,1 10,3 Z')
    } else {
        [System.Windows.Media.Geometry]::Parse('M10,5 A5,5 0 1,1 9.99,5 Z M10,1 L10,3 M10,17 L10,19 M1,10 L3,10 M17,10 L19,10')
    }
}

# ---------------------------------------------------------------------------
# Activity log
# ---------------------------------------------------------------------------
function Protect-Text {
    <# Never let a secret reach the activity log or a saved log file. #>
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)(--(?:clientSecret|password|certificatePassword)\s+)(\S+)', '$1<redacted>')
    $t = [regex]::Replace($t, '(?i)\b(client[_-]?secret|password|api[_-]?key|access[_-]?token|refresh[_-]?token)\b(\s*[:=]\s*)(\S+)', '$1$2<redacted>')
    $t = [regex]::Replace($t, '(?i)\b(bearer\s+)[A-Za-z0-9\-\._~\+/]{20,}=*', '$1<redacted>')
    $t = [regex]::Replace($t, '\beyJ[A-Za-z0-9\-_]{10,}\.[A-Za-z0-9\-_\.]{10,}', '<redacted-token>')
    return $t
}

function Test-ShowLevel {
    param([string]$Level)
    switch ($ctl.CmbFilter.SelectedIndex) {
        1 { return $Level -in @('STEP','OK','FAIL','WARN') }
        2 { return $Level -in @('FAIL','WARN') }
        default { return $true }
    }
}

function Add-Activity {
    param([string]$Level, [string]$Text)
    $r = New-Object ActivityRow
    $r.Time    = (Get-Date).ToString('HH:mm:ss')
    $r.Level   = $Level
    $r.Message = Protect-Text $Text
    $script:AllActivity.Add($r)
    [void]$script:RawLog.AppendLine(('[{0}] {1,-5} {2}' -f $r.Time, $Level, $r.Message))

    if ($script:AllActivity.Count -gt 4000) { $script:AllActivity.RemoveRange(0, 1000) }

    if (Test-ShowLevel $Level) {
        $script:View.Add($r)
        while ($script:View.Count -gt 1500) { $script:View.RemoveAt(0) }
        # While draining a burst of CLI output, scroll once at the end rather
        # than once per line - ScrollIntoView forces a layout pass each call.
        if ($script:LogOpen -and -not $script:Draining) { $ctl.LvLog.ScrollIntoView($r) }
    }
    if ($Level -in @('STEP','OK','FAIL','WARN')) { $ctl.TbLastStatus.Text = $r.Message }
}

function Update-LogScroll {
    if ($script:LogOpen -and $script:View.Count -gt 0) {
        $ctl.LvLog.ScrollIntoView($script:View[$script:View.Count - 1])
    }
}

function Sync-ActivityView {
    $script:View.Clear()
    $start = [Math]::Max(0, $script:AllActivity.Count - 1500)
    for ($i = $start; $i -lt $script:AllActivity.Count; $i++) {
        $r = $script:AllActivity[$i]
        if (Test-ShowLevel $r.Level) { $script:View.Add($r) }
    }
    if ($script:View.Count -gt 0) { $ctl.LvLog.ScrollIntoView($script:View[$script:View.Count-1]) }
}

function Write-Err {
    param($Rec, [string]$Where = 'Operation')
    Add-Activity 'FAIL' ("{0} failed: {1}" -f $Where, $Rec.Exception.Message)
    Add-Activity 'OUT'  ("type: {0}" -f $Rec.Exception.GetType().FullName)
    if ($Rec.InvocationInfo) { Add-Activity 'OUT' ("line {0}: {1}" -f $Rec.InvocationInfo.ScriptLineNumber, $Rec.InvocationInfo.Line.Trim()) }
}

# ---------------------------------------------------------------------------
# Security helpers
# ---------------------------------------------------------------------------
function Get-FullPath {
    param([string]$Path)
    try { return [IO.Path]::GetFullPath($Path) } catch { return $null }
}

function Test-InsidePath {
    <# True only if Child resolves to something under Parent. Guards every delete. #>
    param([string]$Child, [string]$Parent)
    $c = Get-FullPath $Child; $p = Get-FullPath $Parent
    if (-not $c -or -not $p) { return $false }
    if (-not $p.EndsWith([IO.Path]::DirectorySeparatorChar)) { $p += [IO.Path]::DirectorySeparatorChar }
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

function Test-EnvUrl {
    param([string]$Url)
    if ($Url -notmatch '^https://') { Add-Activity 'FAIL' "Environment URL must start with https://"; return $false }
    if ($Url -match '@')            { Add-Activity 'FAIL' "Environment URL must not contain credentials."; return $false }
    if ($Url -notmatch '(?i)\.(dynamics\.com|dynamics\.cn|microsoftdynamics\.us|crm[0-9]*\.dynamics\.com)(/|$)') {
        Add-Activity 'WARN' "That URL does not look like a Dataverse environment: $Url"
    }
    return $true
}

# ---------------------------------------------------------------------------
# Background job runner
#
# Everything slow runs in its own runspace. The UI thread only drains a queue
# on a timer, so the window never freezes and - because Start-Work refuses to
# start while another job is live - two operations can never interleave.
# ---------------------------------------------------------------------------
$script:Prelude = @'
$ErrorActionPreference = 'Continue'
function WQ   { param([string]$L,[string]$T) $Q.Enqueue([pscustomobject]@{Level=$L;Text=$T}) }
# Progress: current step, total steps, what is happening. The UI turns this
# into a real percentage bar instead of an endless indeterminate sweep.
function WProg { param([int]$Cur,[int]$Total,[string]$Label) WQ 'PROG' ("{0}|{1}|{2}" -f $Cur,$Total,$Label) }
function WStep{ param([string]$t) WQ 'STEP' $t }
function WLog { param([string]$t) WQ 'INFO' $t }
function WOk  { param([string]$t) WQ 'OK'   $t }
function WErr { param([string]$t) WQ 'FAIL' $t }
function WWarn{ param([string]$t) WQ 'WARN' $t }
function WOut { param([string]$t) WQ 'OUT'  $t }

function ResolveExe {
    param([string]$Name)
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    $probe = @()
    if ($Name -eq 'pac') {
        $probe = @("$env:USERPROFILE\.dotnet\tools\pac.exe",
                   "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\pac.exe",
                   "$env:LOCALAPPDATA\Microsoft\PowerAppsCLI\tools\pac.exe",
                   "$env:ProgramFiles\Microsoft Power Platform CLI\pac.exe")
    } elseif ($Name -eq 'dotnet') {
        $probe = @("$env:ProgramFiles\dotnet\dotnet.exe", "${env:ProgramFiles(x86)}\dotnet\dotnet.exe")
    }
    foreach ($p in $probe) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function RunCli {
    param([string]$Exe, [string[]]$Arguments, [string]$WorkDir, [switch]$Quiet)
    $script:CliOut = ''
    $full = ResolveExe $Exe
    if (-not $full) {
        WErr "'$Exe' was not found on PATH."
        if ($Exe -eq 'pac')    { WOut "dotnet tool install --global Microsoft.PowerApps.CLI.Tool ; pac install latest" }
        if ($Exe -eq 'dotnet') { WOut "Install the .NET SDK from https://dotnet.microsoft.com/download" }
        return 9009
    }
    if (-not $WorkDir) { $WorkDir = $env:TEMP }
    if (-not (Test-Path -LiteralPath $WorkDir)) { WErr "working directory missing: $WorkDir"; return 9009 }

    WQ 'CMD' ("{0} {1}" -f (Split-Path -Leaf $full), ($Arguments -join ' '))
    $prev = Get-Location
    $code = 9009
    $sb   = New-Object System.Text.StringBuilder
    try {
        Set-Location -LiteralPath $WorkDir
        $global:LASTEXITCODE = 0
        # The call operator quotes each argument correctly on its own.
        $out  = & $full @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        foreach ($l in @($out)) {
            if ($null -eq $l) { continue }
            $s = if ($l -is [System.Management.Automation.ErrorRecord]) { $l.ToString() } else { [string]$l }
            [void]$sb.AppendLine($s)
            if (-not $Quiet) { foreach ($one in ($s -split "`r?`n")) { if ($one.Trim()) { WOut $one.TrimEnd() } } }
        }
    } catch {
        WErr $_.Exception.Message
        $code = 9009
    } finally { Set-Location $prev }
    $script:CliOut = $sb.ToString()
    if ($code -ne 0) { WErr "exit code $code" }
    return $code
}

function IsBlocked {
    # Must go through the -Stream parameter. Concatenating "path:Zone.Identifier"
    # into a single string is rejected by .NET and by the FileSystem provider
    # with "The given path's format is not supported."
    param([string]$Path)
    try { return [bool](Get-Item -LiteralPath $Path -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) }
    catch { return $false }
}

function FastUnblock {
    param([string[]]$Paths)
    # Test first so the count is honest and Unblock-File only runs where it is
    # actually needed - most files in a locally built package are never blocked.
    $n = 0
    foreach ($p in $Paths) {
        try {
            if (IsBlocked $p) {
                Unblock-File -LiteralPath $p -ErrorAction SilentlyContinue
                if (-not (IsBlocked $p)) { $n++ }
            }
        } catch { }
    }
    return $n
}

function InsidePath {
    param([string]$Child, [string]$Parent)
    try {
        $c = [IO.Path]::GetFullPath($Child); $p = [IO.Path]::GetFullPath($Parent)
        if (-not $p.EndsWith([IO.Path]::DirectorySeparatorChar)) { $p += [IO.Path]::DirectorySeparatorChar }
        return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function ReadBaseline {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in (Get-Content -LiteralPath $File)) { if ($l.Trim()) { [void]$set.Add($l.Trim()) } }
    if ($set.Count -eq 0) { return $null }
    return ,$set
}

function GetArtifacts {
    param([string]$Root, [string]$BaselineFile, [string]$ProtectedRegex)
    $base = ReadBaseline $BaselineFile
    $files = @(); $folders = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue)) {
        if ($null -ne $base) { if (-not $base.Contains($f.Name)) { $files += $f } }
        elseif ($f.Extension -in @('.dll','.pdb') -and $f.Name -notmatch $ProtectedRegex) { $files += $f }
        elseif ($f.Name -eq '[Content_Types].xml') { $files += $f }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($null -ne $base) { if (-not $base.Contains('DIR:' + $d.Name)) { $folders += $d } }
        elseif ($d.Name -in @('PkgAssets','PkgFolder') -or (Test-Path -LiteralPath (Join-Path $d.FullName 'ImportConfig.xml'))) { $folders += $d }
    }
    return [pscustomobject]@{ Files = $files; Folders = $folders }
}

function ResolvePackageRoot {
    param([string]$Start)
    $cfgs = @(Get-ChildItem -LiteralPath $Start -Recurse -File -Filter 'ImportConfig.xml' -ErrorAction SilentlyContinue)
    if ($cfgs.Count -eq 0) {
        WErr "no ImportConfig.xml found under: $Start"
        foreach ($i in @(Get-ChildItem -LiteralPath $Start -ErrorAction SilentlyContinue | Select-Object -First 20)) {
            WOut ("{0}{1}" -f $i.Name, $(if ($i.PSIsContainer) { '\' } else { '' }))
        }
        return $null
    }
    foreach ($c in $cfgs) {
        $root = $c.Directory.Parent
        if ($null -eq $root) { continue }
        if (@(Get-ChildItem -LiteralPath $root.FullName -Filter *.dll -File -ErrorAction SilentlyContinue).Count -gt 0) { return $root.FullName }
    }
    $fb = $cfgs[0].Directory.Parent
    if ($null -ne $fb) { WWarn "assets found but no .dll beside them"; return $fb.FullName }
    return $null
}
'@

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)

function Set-Progress {
    # "current|total|label" from a worker. Anything unparseable leaves the bar
    # indeterminate, which is the right answer for a step of unknown length.
    param([string]$Payload)
    $bits = $Payload -split '\|', 3
    if ($bits.Count -lt 2) { return }
    $cur = 0; $total = 0
    if (-not [int]::TryParse($bits[0], [ref]$cur))   { return }
    if (-not [int]::TryParse($bits[1], [ref]$total)) { return }
    if ($total -le 0) { return }

    $pct = [Math]::Max(0, [Math]::Min(100, [int](100 * $cur / $total)))
    foreach ($b in @($ctl.PbBusy, $ctl.PbTop)) {
        $b.IsIndeterminate = $false
        $b.Value = $pct
    }
    $ctl.TbOverlayPct.Text = "$pct%"
    if ($bits.Count -ge 3 -and $bits[2]) {
        $ctl.TbOverlaySub.Text = ("Step {0} of {1} - {2}" -f $cur, $total, $bits[2])
        $script:ProgLabel = $true
    }
}

function Set-BusyUi {
    param([bool]$On, [string]$Title = 'Working...')
    $vis = if ($On) { 'Visible' } else { 'Collapsed' }
    $ctl.Overlay.Visibility     = $vis
    $ctl.PbTop.Visibility       = $vis      # thin bar under the header
    $ctl.IcMiniSpin.Visibility  = $vis      # spinner beside the activity status
    $ctl.TbOverlayTitle.Text    = $Title
    $ctl.TbOverlaySub.Text      = 'Starting...'
    $ctl.TbOverlayPct.Text      = ''
    # Navigation stays live while a job runs. Browsing another page is harmless,
    # Start-Work already refuses a second job, and disabling the list was what
    # made WPF repaint the sidebar with its white disabled-state system brush.
    $script:ProgLabel = $false
    # Back to indeterminate for the next job until a worker reports a step.
    foreach ($b in @($ctl.PbBusy, $ctl.PbTop)) { $b.IsIndeterminate = $true; $b.Value = 0 }
    $win.Cursor = if ($On) { [System.Windows.Input.Cursors]::AppStarting } else { $null }
}

function Start-Work {
    <#
      Runs $Work in a fresh runspace. Refuses to start if something is already
      running - that single guard is what stops overlapping actions from
      corrupting each other's state.
    #>
    param([string]$Title, [scriptblock]$Work, [hashtable]$Arguments = @{},
          [scriptblock]$OnDone = $null, [hashtable]$Context = @{})

    if ($script:Busy) {
        Add-Activity 'WARN' "'$($script:BusyTitle)' is still running. Wait for it to finish."
        return
    }
    $script:Busy      = $true
    $script:BusyTitle = $Title
    $script:JobStarted = Get-Date
    Add-Activity 'STEP' $Title
    Set-BusyUi $true $Title

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('Q', $script:Queue)
        $rs.SessionStateProxy.SetVariable('A', $Arguments)

        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:Prelude + "`r`n" + $Work.ToString())

        $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Context = $Context }
        $script:Timer.Start()
    } catch {
        Write-Err $_ 'starting background work'
        $script:Busy = $false
        Set-BusyUi $false
    }
}

$script:Timer.Add_Tick({
  # An unhandled exception in a DispatcherTimer tick takes the whole app down,
  # so nothing in here is allowed to escape.
  try {
    $item = $null
    $script:Draining = $true
    $got = $false
    while ($script:Queue.TryDequeue([ref]$item)) {
        if (-not $item) { continue }
        if ($item.Level -eq 'PROG') { Set-Progress $item.Text; continue }   # not a log row
        Add-Activity $item.Level $item.Text; $got = $true
    }
    $script:Draining = $false
    if ($got) { Update-LogScroll }
    # Show what is happening rather than counting seconds at the user. Once a
    # worker starts reporting steps, Set-Progress owns this line instead.
    if ($script:Busy -and -not $script:ProgLabel -and $ctl.TbLastStatus.Text) {
        $ctl.TbOverlaySub.Text = $ctl.TbLastStatus.Text
    }
    if (-not $script:Job) { return }
    if (-not $script:Job.Handle.IsCompleted) { return }

    $script:Timer.Stop()
    $job = $script:Job
    $script:Job = $null
    $result = $null
    try { $result = $job.PS.EndInvoke($job.Handle) }
    catch { Add-Activity 'FAIL' ("background work failed: " + $_.Exception.Message) }

    foreach ($e in @($job.PS.Streams.Error)) { Add-Activity 'FAIL' ([string]$e) }
    $script:Draining = $true
    while ($script:Queue.TryDequeue([ref]$item)) { if ($item) { Add-Activity $item.Level $item.Text } }
    $script:Draining = $false
    Update-LogScroll

    try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch { }

    $script:Busy = $false
    Set-BusyUi $false

    if ($job.OnDone) {
        # Every worker returns a hashtable as its last output; ignore anything else.
        $payload = $null
        foreach ($r in @($result)) { if ($r -is [hashtable]) { $payload = $r } }
        # The callback gets (result, context). Context carries whatever the
        # caller needed to remember - never a closure: GetNewClosure binds the
        # scriptblock to a new dynamic module, and $script: inside it then
        # points at that module rather than at this script's scope.
        try { & $job.OnDone $payload $job.Context } catch { Write-Err $_ 'completing work' }
    }
  } catch {
    try {
        $script:Draining = $false
        $script:Busy = $false
        Set-BusyUi $false
        Add-Activity 'FAIL' ("activity pump error: " + $_.Exception.Message)
    } catch { }
  }
})

# ---------------------------------------------------------------------------
# Dialogs & small helpers
# ---------------------------------------------------------------------------
function Select-FolderDialog {
    <#
      The real Explorer folder picker, not the old tree-view
      FolderBrowserDialog: OpenFileDialog with name validation switched off
      shows the modern common-item dialog - address bar, places, search - and
      we take the directory of whatever it returns.
    #>
    param([string]$Description, [string]$Start)
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title            = "$Description  -  open the folder, then click Select"
    $d.ValidateNames    = $false
    $d.CheckFileExists  = $false
    $d.CheckPathExists  = $true
    $d.Multiselect      = $false
    $d.Filter           = 'Folders|*.this-never-matches'
    $d.FileName         = 'Select this folder'
    if ($Start -and (Test-Path -LiteralPath $Start)) {
        $d.InitialDirectory = $Start
    } elseif ($Start) {
        $p = Split-Path -Parent $Start
        if ($p -and (Test-Path -LiteralPath $p)) { $d.InitialDirectory = $p }
    }
    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $picked = Split-Path -Parent $d.FileName
    if (-not $picked) { return $null }
    # If they selected a real folder rather than opening it, use that instead.
    if (Test-Path -LiteralPath $d.FileName -PathType Container) { $picked = $d.FileName }
    return $picked
}
function Select-FileDialog {
    param([string]$Title, [string]$Filter, [switch]$Multi, [string]$Start)
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = $Title; $d.Filter = $Filter; $d.Multiselect = [bool]$Multi
    if ($Start -and (Test-Path $Start)) { $d.InitialDirectory = $Start }
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.FileNames }
    return @()
}
function Get-ToolDir { $ctl.TxtTool.Text.Trim().TrimEnd('\') }

function Test-IsToolFolder {
    param([string]$Path)
    if (-not $Path) { return $false }
    try { return (Test-Path -LiteralPath (Join-Path $Path 'PackageDeployer.exe')) } catch { return $false }
}

function Find-ToolFolder {
    <#
      Locate Microsoft's Package Deployer tool without making the user hunt for
      it. Checks where the installer would have put it, then next to the app,
      then any folder beside the app, then the NuGet cache - people who have
      ever restored the PackageDeployment.WPF package already have a copy.
    #>
    $cands = New-Object System.Collections.Generic.List[string]

    $cands.Add((Join-Path $script:AppDir 'PackageDeployertool'))
    $cands.Add((Join-Path $script:AppDir 'PackageDeployerTool'))
    $parent = Split-Path -Parent $script:AppDir
    if ($parent) { $cands.Add((Join-Path $parent 'PackageDeployertool')) }
    $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\PackageDeployerStudio\PackageDeployertool'))

    # any immediate subfolder of the app folder that holds the exe
    foreach ($d in @(Get-ChildItem -LiteralPath $script:AppDir -Directory -ErrorAction SilentlyContinue)) {
        $cands.Add($d.FullName)
    }

    # NuGet package cache
    foreach ($pkg in @('microsoft.crmsdk.xrmtooling.packagedeployment.wpf','microsoft.crmsdk.xrmtooling.packagedeployment')) {
        $root = Join-Path $env:USERPROFILE ".nuget\packages\$pkg"
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($v in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                         Sort-Object Name -Descending)) {
            $cands.Add((Join-Path $v.FullName 'tools'))
            $cands.Add((Join-Path $v.FullName 'content\bin\coretools'))
            $cands.Add($v.FullName)
        }
    }

    foreach ($c in $cands) { if (Test-IsToolFolder $c) { return $c } }
    return $null
}

function Update-ToolBanner {
    $ok = Test-IsToolFolder (Get-ToolDir)
    $ctl.BdNoTool.Visibility = if ($ok) { 'Collapsed' } else { 'Visible' }
    foreach ($b in @('BtnClean','BtnLoad','BtnVerify','BtnLaunch','BtnAll','BtnBaseline')) {
        if (-not $script:Busy) { $ctl[$b].IsEnabled = $ok }
    }
}

function Initialize-ToolFolder {
    # Called at startup. Keeps a valid saved value, otherwise goes looking.
    if (Test-IsToolFolder (Get-ToolDir)) {
        Add-Activity 'OK' "Package Deployer tool: $(Get-ToolDir)"
        Update-ToolBanner
        return
    }
    $found = Find-ToolFolder
    if ($found) {
        $ctl.TxtTool.Text = $found
        Add-Activity 'OK' "Package Deployer tool found automatically: $found"
        Save-Settings
    } else {
        if (-not $ctl.TxtTool.Text) { $ctl.TxtTool.Text = Join-Path $script:AppDir 'PackageDeployertool' }
        Add-Activity 'WARN' "Microsoft's Package Deployer tool was not found on this machine."
        Add-Activity 'OUT' "Only Clean / Load / Verify / Launch need it - 'Deploy package' with the PAC CLI does not."
        Add-Activity 'OUT' "Get it from the Microsoft.CrmSdk.XrmTooling.PackageDeployment.WPF NuGet package,"
        Add-Activity 'OUT' "extract its tools\ folder to $($ctl.TxtTool.Text), then restart - or click Browse on the Deploy page."
    }
    Update-ToolBanner
}

function Test-ToolDir {
    $t = Get-ToolDir
    if (-not $t)                          { Add-Activity 'FAIL' "Tool folder is not set."; return $false }
    if (-not (Test-Path -LiteralPath $t)) { Add-Activity 'FAIL' "Tool folder does not exist: $t"; return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $t 'PackageDeployer.exe'))) {
        Add-Activity 'FAIL' "PackageDeployer.exe not found in: $t"; return $false }
    return $true
}

function Read-Baseline {
    if (-not (Test-Path -LiteralPath $script:BaselineFile)) { return $null }
    $stamp = (Get-Item -LiteralPath $script:BaselineFile).LastWriteTimeUtc
    if ($script:BaselineCache -and $script:BaselineStamp -eq $stamp) { return ,$script:BaselineCache }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($l in (Get-Content -LiteralPath $script:BaselineFile)) { if ($l.Trim()) { [void]$set.Add($l.Trim()) } }
    if ($set.Count -eq 0) { return $null }
    $script:BaselineCache = $set; $script:BaselineStamp = $stamp
    return ,$set
}

function Get-AssetFolders {
    param([string]$Root)
    $r = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'ImportConfig.xml')) { $r += $d }
        elseif ($d.Name -in @('PkgAssets','PkgFolder')) { $r += $d }
    }
    return $r
}

function Get-PackageArtifacts {
    param([string]$Root)
    $base = Read-Baseline
    $files = @(); $folders = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue)) {
        if ($null -ne $base) { if (-not $base.Contains($f.Name)) { $files += $f } }
        elseif ($f.Extension -in @('.dll','.pdb') -and $f.Name -notmatch $script:ProtectedRegex) { $files += $f }
        elseif ($f.Name -eq '[Content_Types].xml') { $files += $f }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($null -ne $base) { if (-not $base.Contains('DIR:' + $d.Name)) { $folders += $d } }
        elseif ($d.Name -in @('PkgAssets','PkgFolder') -or (Test-Path -LiteralPath (Join-Path $d.FullName 'ImportConfig.xml'))) { $folders += $d }
    }
    return [pscustomobject]@{ Files = $files; Folders = $folders }
}

function Update-State {
    $t = Get-ToolDir
    if (-not $t -or -not (Test-Path -LiteralPath $t)) { $ctl.TbState.Text = 'Tool folder not found.'; return }
    $baseTxt = if (Test-Path -LiteralPath $script:BaselineFile) { 'recorded' } else { 'NONE - click Snapshot on a clean folder' }
    $art     = Get-PackageArtifacts -Root $t
    $assets  = Get-AssetFolders -Root $t
    $dlls    = @($art.Files | Where-Object { $_.Extension -eq '.dll' })
    $lines   = @("Baseline    : $baseTxt")
    if ($assets.Count -eq 0) { $lines += "Assets      : none - folder is clean" }
    else {
        foreach ($a in $assets) {
            $zip = @(Get-ChildItem -LiteralPath $a.FullName -Filter *.zip -ErrorAction SilentlyContinue).Count
            $lines += ("Assets      : {0}  (ImportConfig.xml: {1}, zips: {2})" -f $a.Name,
                       (Test-Path -LiteralPath (Join-Path $a.FullName 'ImportConfig.xml')), $zip)
        }
    }
    $lines += ("Package dll : {0}" -f $(if ($dlls.Count -eq 0) { 'none' } else { ($dlls | ForEach-Object { $_.Name }) -join ', ' }))
    if ($dlls.Count -gt 1) { $lines += "WARNING: more than one package dll present." }
    $ctl.TbState.Text = $lines -join "`r`n"
}

function Show-PackageSummary {
    <#
      Inspect whatever the user just picked and say what it is, so "which one
      do I choose" is answered by the app rather than by guesswork.
    #>
    param([string]$Path, [string]$Where = 'Package')
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { Add-Activity 'FAIL' "$Where not found: $Path"; return }

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            if ([IO.Path]::GetExtension($Path) -ne '.zip') {
                Add-Activity 'WARN' "$Where is a file but not a .zip - pick the .pdpkg.zip, or the publish folder."
                return
            }
            $zf = [IO.Compression.ZipFile]::OpenRead($Path)
            try {
                $names = @($zf.Entries | ForEach-Object { $_.FullName })
                $cfg   = @($names | Where-Object { $_ -match '(^|/)ImportConfig\.xml$' })
                $dlls  = @($names | Where-Object { $_ -match '^[^/]+\.dll$' })
                $sols  = @($names | Where-Object { $_ -match '\.zip$' })
                if ($cfg.Count -eq 0) {
                    Add-Activity 'WARN' "No ImportConfig.xml inside this zip - it may not be a Package Deployer package."
                } else {
                    Add-Activity 'OK' ("$Where looks right: {0} solution zip(s), assembly {1}" -f
                        $sols.Count, $(if ($dlls.Count) { $dlls[0] } else { 'not at the root' }))
                }
            } finally { $zf.Dispose() }
            return
        }

        # a folder
        $cfg = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter 'ImportConfig.xml' -ErrorAction SilentlyContinue |
                 Select-Object -First 1)
        if ($cfg.Count -eq 0) {
            Add-Activity 'WARN' "No ImportConfig.xml under this folder."
            Add-Activity 'OUT' "Pick the publish folder - the one holding <Name>.dll next to PkgAssets\ - or the .pdpkg.zip."
            return
        }
        $assets = $cfg[0].Directory
        $root   = $assets.Parent
        $dll    = @(Get-ChildItem -LiteralPath $root.FullName -Filter *.dll -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -notmatch $script:ProtectedRegex } | Select-Object -First 1)
        $zips   = @(Get-ChildItem -LiteralPath $assets.FullName -Filter *.zip -ErrorAction SilentlyContinue).Count
        Add-Activity 'OK' ("$Where looks right: {0}\ with {1} solution zip(s), assembly {2}" -f
            $assets.Name, $zips, $(if ($dll.Count) { $dll[0].Name } else { 'MISSING' }))
        if ($dll.Count -eq 0) { Add-Activity 'WARN' "No package assembly beside $($assets.Name) - the tool will not see a package." }
    } catch {
        Add-Activity 'WARN' ("could not inspect the $Where`: " + $_.Exception.Message)
    }
}

function Update-EnvChip {
    # SetResourceReference is the code equivalent of DynamicResource, so these
    # two follow the theme instead of freezing to whatever was current.
    $key = if ($script:CurrentEnv) { 'Success' } else { 'Danger' }
    $ctl.TbEnvChip.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $key)
    $ctl.EnvDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $key)
    if ($script:CurrentEnv) {
        $ctl.TbEnvChip.Text = $script:CurrentEnv.Name
        $ctl.EnvDot.ToolTip = "Connected to $($script:CurrentEnv.Name)"
    } else {
        $ctl.TbEnvChip.Text = 'Not connected'
        $ctl.EnvDot.ToolTip = 'Not connected'
    }
}

function Get-Prop {
    param($Obj, [string[]]$Names, $Default = '')
    foreach ($n in $Names) {
        $p = $Obj.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value -and "$($p.Value)".Trim()) { return "$($p.Value)".Trim() }
    }
    return $Default
}

# ---------------------------------------------------------------------------
# Workers
# ---------------------------------------------------------------------------
$script:WorkEnvList = {
    $code = RunCli -Exe 'pac' -Arguments @('env','list') -WorkDir $A.AppDir -Quiet
    if ($code -ne 0) {
        WErr "pac env list failed. Sign in first."
        foreach ($l in ($script:CliOut -split "`r?`n")) { if ($l.Trim()) { WOut $l } }
        return @{ ok = $false }
    }
    $rows = @()
    foreach ($line in ($script:CliOut -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $m = [regex]::Match($line, 'https://[^\s]+')
        if (-not $m.Success) { continue }
        $raw  = $m.Value
        $head = $line.Substring(0, $m.Index)
        $tail = $line.Substring($m.Index + $raw.Length)
        $g    = [regex]::Match($tail, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        $name = ($head -replace '^\s*\[\d+\]\s*','' -replace '^\s*\*\s*','').Trim()
        if (-not $name) { $name = $raw }
        $rows += [pscustomobject]@{ Name = $name; Url = $raw.TrimEnd('/'); Id = $(if ($g.Success) { $g.Value } else { '' }) }
    }
    if ($rows.Count -eq 0) {
        WWarn "No environments parsed. Raw output:"
        foreach ($l in ($script:CliOut -split "`r?`n")) { if ($l.Trim()) { WOut $l } }
    } else {
        WOk "found $($rows.Count) environment(s)"
    }
    return @{ ok = $true; rows = $rows }
}

$script:WorkSolList = {
    $args = @('solution','list','--json')
    if ($A.IncludeSystem) { $args += '--includeSystemSolutions' }
    $code = RunCli -Exe 'pac' -Arguments $args -WorkDir $A.AppDir -Quiet
    if ($code -ne 0) {
        WErr "pac solution list failed."
        foreach ($l in ($script:CliOut -split "`r?`n")) { if ($l.Trim()) { WOut $l } }
        return @{ ok = $false }
    }
    $txt = $script:CliOut
    $i   = $txt.IndexOfAny([char[]]@('[','{'))
    if ($i -lt 0) {
        WErr "No JSON in the response."
        foreach ($l in ($txt -split "`r?`n")) { if ($l.Trim()) { WOut $l } }
        return @{ ok = $false }
    }
    try { $data = $txt.Substring($i) | ConvertFrom-Json }
    catch { WErr ("could not parse solution JSON: " + $_.Exception.Message); return @{ ok = $false } }
    WOk "received $(@($data).Count) solution record(s)"
    return @{ ok = $true; data = @($data) }
}

$script:WorkExport = {
    $done = 0; $failed = 0; $made = @()
    $steps = $A.Solutions.Count * $A.Kinds.Count
    $n = 0
    foreach ($s in $A.Solutions) {
        foreach ($managed in $A.Kinds) {
            $n++
            WProg $n $steps ("exporting " + $s)
            $suffix = if ($managed) { '_managed' } else { '_unmanaged' }
            $file   = Join-Path $A.Dir ("{0}{1}.zip" -f $s, $suffix)
            WLog ("exporting {0} ({1})" -f $s, $(if ($managed) { 'managed' } else { 'unmanaged' }))
            $args = @('solution','export','--path',$file,'--name',$s,'--overwrite')
            if ($managed) { $args += '--managed' }      # --managed is a switch, not a value
            if ((RunCli -Exe 'pac' -Arguments $args -WorkDir $A.AppDir) -eq 0 -and (Test-Path -LiteralPath $file)) {
                $mb = [math]::Round((Get-Item -LiteralPath $file).Length / 1MB, 2)
                WOk ("exported {0} ({1} MB)" -f (Split-Path -Leaf $file), $mb)
                $made += $file; $done++
            } else { WErr "export failed: $s"; $failed++ }
        }
    }
    if ($failed -gt 0) { WWarn "export finished - $done ok, $failed failed" } else { WOk "export finished - $done file(s)" }
    return @{ ok = ($failed -eq 0); made = $made }
}

$script:WorkImport = {
    $args = @('solution','import','--path',$A.Zip)
    if ($A.Publish)  { $args += '--publish-changes' }
    if ($A.Activate) { $args += '--activate-plugins' }
    if ($A.Force)    { $args += '--force-overwrite' }
    if ($A.Upgrade)  { $args += '--stage-and-upgrade' }
    WLog "This can take a long time for large solutions."
    $code = RunCli -Exe 'pac' -Arguments $args -WorkDir $A.AppDir
    if ($code -eq 0) { WOk "import succeeded" } else { WErr "import failed" }
    return @{ ok = ($code -eq 0) }
}

$script:WorkCreatePackage = {
    $name = $A.Name; $out = $A.OutDir; $proj = Join-Path $out $name

    if ($A.Wipe -and (Test-Path -LiteralPath $proj)) {
        if (-not (InsidePath $proj $out)) { WErr "refusing to delete outside the output folder: $proj"; return @{ ok = $false } }
        try { Remove-Item -LiteralPath $proj -Recurse -Force; WLog "removed existing $name\" }
        catch { WErr ("could not remove existing folder: " + $_.Exception.Message); return @{ ok = $false } }
    }

    $steps = $A.Solutions.Count + 3
    WProg 1 $steps "creating the package project"
    if ((RunCli -Exe 'pac' -Arguments @('package','init','-o',$name) -WorkDir $out) -ne 0) {
        WErr "pac package init failed."; return @{ ok = $false }
    }
    if (-not (Test-Path -LiteralPath $proj)) { WErr "project folder was not created: $proj"; return @{ ok = $false } }
    WOk "project created: $proj"

    $i = 0
    foreach ($s in $A.Solutions) {
        $i++
        if (-not (Test-Path -LiteralPath $s)) { WWarn "not found, skipped: $s"; continue }
        WProg (1 + $i) $steps ("adding " + (Split-Path -Leaf $s))
        WLog ("adding solution {0}/{1}: {2}" -f $i, $A.Solutions.Count, (Split-Path -Leaf $s))
        if ((RunCli -Exe 'pac' -Arguments @('package','add-solution','-p',$s) -WorkDir $proj) -ne 0) {
            WErr "add-solution failed for $s"; return @{ ok = $false }
        }
    }

    WProg ($steps - 1) $steps "building the package (dotnet publish)"
    if ((RunCli -Exe 'dotnet' -Arguments @('publish') -WorkDir $proj) -ne 0) {
        WErr "dotnet publish failed."; return @{ ok = $false }
    }

    WProg $steps $steps "locating the build output"
    WLog 'locating build output ...'
    $zip = @(Get-ChildItem -LiteralPath $proj -Recurse -File -Filter '*.pdpkg.zip' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $zipPath = if ($zip.Count -gt 0) { $zip[0].FullName } else { $null }
    $dirPath = ResolvePackageRoot -Start $proj
    if (-not $zipPath -and -not $dirPath) { WErr "publish succeeded but no package output was found under $proj"; return @{ ok = $false } }
    if ($zipPath) { WOk "package zip   : $zipPath" }
    if ($dirPath) { WOk "package folder: $dirPath" }
    return @{ ok = $true; zip = $zipPath; dir = $dirPath }
}

$script:WorkClean = {
    $t = $A.ToolDir
    if (-not (Test-Path -LiteralPath (Join-Path $t 'PackageDeployer.exe'))) { WErr "not a tool folder: $t"; return @{ ok = $false } }
    if (-not (Test-Path -LiteralPath $A.BaselineFile)) {
        WWarn "No baseline - falling back to name rules. Snapshot a clean folder for exact cleaning."
    }
    $art = GetArtifacts $t $A.BaselineFile $A.ProtectedRegex
    $removed = 0
    foreach ($d in $art.Folders) {
        if (-not (InsidePath $d.FullName $t)) { WErr "refusing to delete outside the tool folder: $($d.FullName)"; return @{ ok = $false } }
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force; WLog "removed folder  $($d.Name)"; $removed++ }
        catch { WErr ("could not remove $($d.Name): " + $_.Exception.Message); return @{ ok = $false } }
    }
    foreach ($f in $art.Files) {
        if ($f.Name -eq 'PackageDeployer.tokens.dat' -and -not $A.DeleteTokens) { continue }
        if (-not (InsidePath $f.FullName $t)) { WErr "refusing to delete outside the tool folder: $($f.FullName)"; return @{ ok = $false } }
        try { Remove-Item -LiteralPath $f.FullName -Force; WLog "removed file    $($f.Name)"; $removed++ }
        catch { WErr ("could not remove $($f.Name): " + $_.Exception.Message); return @{ ok = $false } }
    }
    if ($A.DeleteTokens) {
        # The tool-folder copy is not the one that matters. Package Deployer
        # caches its token as %APPDATA%\Microsoft\PackageDeployer\
        # Default_PackageDeployer.tokens.dat and remembers the last environment
        # in Default_PackageDeployer.exe.config beside it. Miss those two and
        # it silently signs back in as the previous account on every run.
        $tok = Join-Path $t 'PackageDeployer.tokens.dat'
        if (Test-Path -LiteralPath $tok) {
            try { Remove-Item -LiteralPath $tok -Force; WOk "forgot the tool-folder token"; $removed++ } catch { }
        }
        if ($A.ProfileDir -and (Test-Path -LiteralPath $A.ProfileDir)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $A.ProfileDir -File -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -like '*.tokens.dat' -or $_.Name -like '*.exe.config' })) {
                if (-not (InsidePath $f.FullName $A.ProfileDir)) { continue }   # never stray, never touch the logs
                try { Remove-Item -LiteralPath $f.FullName -Force; WOk "forgot $($f.Name)"; $removed++ }
                catch { WWarn "could not remove $($f.Name) - close Package Deployer and retry" }
            }
        }
    }
    if ($removed -eq 0) { WOk "Already clean." } else { WOk "Clean complete - $removed item(s) removed." }
    return @{ ok = $true }
}

$script:WorkLoad = {
    $t = $A.ToolDir; $src = $A.Source
    if (-not (Test-Path -LiteralPath $src)) { WErr "not found: $src"; return @{ ok = $false } }

    WProg 1 4 "reading the package"
    $work = $src; $temp = $null
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        if ([IO.Path]::GetExtension($src) -ne '.zip') { WErr "expected a folder or a .zip"; return @{ ok = $false } }
        $temp = Join-Path $env:TEMP ('pdstudio_' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        WLog "extracting $(Split-Path -Leaf $src)"
        try {
            [void][System.Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem')
            $zf = [IO.Compression.ZipFile]::OpenRead($src)
            try {
                [void](New-Item -ItemType Directory -Path $temp -Force)
                foreach ($e in $zf.Entries) {
                    if (-not $e.Name) { continue }                       # directory entry
                    $dest = Join-Path $temp $e.FullName
                    # Zip-slip guard: an entry named ..\..\evil.dll must not escape.
                    if (-not (InsidePath $dest $temp)) { WErr "blocked unsafe zip entry: $($e.FullName)"; continue }
                    $dir = Split-Path -Parent $dest
                    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                }
            } finally { $zf.Dispose() }
        } catch { WErr ("extract failed: " + $_.Exception.Message); return @{ ok = $false } }
        $work = $temp
    }

    WProg 2 4 "locating the package"
    $root = ResolvePackageRoot -Start $work
    if (-not $root) { WErr "no package found inside '$src'"; return @{ ok = $false } }

    WProg 3 4 "copying into the tool folder"
    $copied = 0; $touched = New-Object System.Collections.Generic.List[string]
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'ImportConfig.xml'))) { continue }
        $dest = Join-Path $t $d.Name
        if (-not (InsidePath $dest $t)) { WErr "unsafe destination: $dest"; return @{ ok = $false } }
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        WLog "copying $($d.Name)\ ..."
        Copy-Item -LiteralPath $d.FullName -Destination $t -Recurse -Force
        foreach ($f in @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue)) { $touched.Add($f.FullName) }
        WOk "copied  $($d.Name)\"
        $copied++
    }

    $base = ReadBaseline $A.BaselineFile
    foreach ($f in @(Get-ChildItem -LiteralPath $root -File)) {
        if ($f.Extension -notin @('.dll','.pdb','.xml')) { continue }
        if ($f.Extension -eq '.xml' -and $f.Name -ne '[Content_Types].xml') { continue }
        $ships = $false
        if ($null -ne $base) { $ships = $base.Contains($f.Name) }
        elseif ($f.Extension -eq '.dll' -and $f.BaseName -match $A.ProtectedRegex) { $ships = $true }
        if ($ships) { WLog "skipped $($f.Name) (ships with the tool)"; continue }
        Copy-Item -LiteralPath $f.FullName -Destination $t -Force
        $touched.Add((Join-Path $t $f.Name))
        WOk "copied  $($f.Name)"
        $copied++
    }
    if ($copied -eq 0) { WErr "nothing was copied"; return @{ ok = $false } }

    # Only the files we just brought in need unblocking, unless this is the
    # first run - that keeps Load fast instead of walking 550 tool files.
    WProg 4 4 "unblocking files"
    if ($A.FullUnblock) {
        WLog "first run: unblocking the whole tool folder ..."
        $all = @(Get-ChildItem -LiteralPath $t -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $n = FastUnblock $all
        WOk "unblocked $n file(s)"
    } else {
        $n = FastUnblock $touched.ToArray()
        WOk "unblocked $n newly copied file(s)"
    }

    if ($temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    WOk "Load complete."
    return @{ ok = $true }
}

$script:WorkVerify = {
    $t = $A.ToolDir; $ok = $true
    WOk "PackageDeployer.exe present"
    $art  = GetArtifacts $t $A.BaselineFile $A.ProtectedRegex
    $dlls = @($art.Files | Where-Object { $_.Extension -eq '.dll' })
    if     ($dlls.Count -eq 1) { WOk "one package assembly: $($dlls[0].Name)" }
    elseif ($dlls.Count -eq 0) { WErr "no package assembly - the tool will say 'No Import packages found'"; $ok = $false }
    else { WErr "$($dlls.Count) assemblies found - clean and reload"; $ok = $false }

    $assets = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $t -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'ImportConfig.xml')) { $assets += $d }
        elseif ($d.Name -in @('PkgAssets','PkgFolder')) { $assets += $d }
    }
    if ($assets.Count -eq 0) { WErr "no assets folder found"; return @{ ok = $false } }
    if ($assets.Count -gt 1) { WErr "$($assets.Count) assets folders - only one package may be present"; $ok = $false }

    foreach ($a in $assets) {
        $cfg = Join-Path $a.FullName 'ImportConfig.xml'
        if (-not (Test-Path -LiteralPath $cfg)) { WErr "$($a.Name)\ImportConfig.xml missing"; $ok = $false; continue }
        WOk "$($a.Name)\ImportConfig.xml present"
        try { $x = [xml](Get-Content -LiteralPath $cfg -Raw) }
        catch { WErr ("ImportConfig.xml is not valid XML: " + $_.Exception.Message); $ok = $false; continue }
        foreach ($s in @($x.SelectNodes('//configsolutionfile'))) {
            $nm = $s.GetAttribute('solutionpackagefilename')
            if (-not $nm) { continue }
            $p = Join-Path $a.FullName $nm
            if (Test-Path -LiteralPath $p) {
                WOk ("  solution {0}  ({1} MB)" -f $nm, [math]::Round((Get-Item -LiteralPath $p).Length / 1MB, 2))
            } else { WErr ("  solution {0}  MISSING" -f $nm); $ok = $false }
        }
    }

    $check = @($art.Files | ForEach-Object { $_.FullName })
    foreach ($a in $assets) { $check += @(Get-ChildItem -LiteralPath $a.FullName -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
    $blocked = 0
    $blockedNames = @()
    foreach ($p in $check) { if (IsBlocked $p) { $blocked++; $blockedNames += (Split-Path -Leaf $p) } }
    if ($blocked -gt 0) {
        WErr "$blocked file(s) still blocked by Windows - run Load again"
        foreach ($b in ($blockedNames | Select-Object -First 10)) { WOut "  blocked: $b" }
        $ok = $false
    } else { WOk "no blocked files" }

    if ($ok) { WOk "VERIFY PASSED." } else { WErr "VERIFY FAILED." }
    return @{ ok = $ok }
}

$script:WorkDeploy = {
    $code = RunCli -Exe 'pac' -Arguments @('package','deploy','--package',$A.Package,'--logFile',$A.LogFile) -WorkDir $A.AppDir
    if ($code -eq 0) { WOk "DEPLOYMENT SUCCEEDED." } else { WErr "DEPLOYMENT FAILED - read $($A.LogFile)" }
    WOut "Post-deploy: bind connection references, fill environment variables, turn cloud flows on."
    return @{ ok = ($code -eq 0) }
}

$script:WorkPac = {
    # Generic single pac command.
    $code = RunCli -Exe 'pac' -Arguments $A.Args -WorkDir $A.AppDir
    return @{ ok = ($code -eq 0) }
}

$script:WorkSignIn = {
    # pac auth create prompts for credentials and opens the Microsoft sign-in
    # page, so it needs a real console of its own - no redirection, no hidden
    # window. Running it from here keeps the app itself responsive meanwhile.
    $exe = ResolveExe 'pac'
    if (-not $exe) {
        WErr "'pac' was not found on PATH."
        WOut "dotnet tool install --global Microsoft.PowerApps.CLI.Tool ; pac install latest"
        return @{ ok = $false }
    }
    WQ 'CMD' ("pac " + ($A.Args -join ' '))
    WWarn 'Complete the sign-in in the console window that just opened, then come back here.'
    $quoted = @($A.Args | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"','\"') + '"' } else { $_ } })
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $quoted -WorkingDirectory $A.AppDir -Wait -PassThru
        $code = if ($null -eq $p.ExitCode) { 0 } else { $p.ExitCode }
    } catch { WErr $_.Exception.Message; return @{ ok = $false } }
    if ($code -ne 0) {
        WErr "Sign-in was cancelled or failed (exit code $code)."
        WOut "If no window appeared, tick 'Use device code instead' and try again."
        return @{ ok = $false }
    }
    WOk "Signed in."
    return @{ ok = $true }
}

$script:WorkRegion = {
    <#
      Where does this machine's traffic actually leave from?

      A split-tunnel VPN routes only some subnets, so it is entirely possible to
      be "on the VPN" while Dataverse traffic still leaves via the local ISP.
      This asks an external service what public IP it sees, which is the only
      thing that reliably answers the question before a long deployment.
      The URL is configurable so it can point at an internal endpoint instead.
    #>
    WStep 'Checking the outbound address'
    WOut "Calling $($A.Url) - the only outbound call this app makes on its own."
    try {
        $r = Invoke-RestMethod -Uri $A.Url -TimeoutSec 20 -ErrorAction Stop
    } catch {
        WErr ("Could not reach the lookup service: " + $_.Exception.Message)
        WOut "That may itself mean the tunnel blocks it. Check with your usual tooling."
        return @{ ok = $false }
    }

    $ip  = $r.ip
    $org = $r.org
    # -join, not Join-String: this app runs on Windows PowerShell 5.1.
    $loc = (@($r.city, $r.region, $r.country) | Where-Object { $_ }) -join ', '
    if (-not $ip) { WErr "The service returned no IP field."; return @{ ok = $false } }

    WOk  "Public IP : $ip"
    if ($loc) { WOk "Location  : $loc" }
    if ($org) { WOk "Network   : $org" }
    WOut ''
    WOut "If that is not the region you expect, your VPN is not carrying this"
    WOut "traffic - a split tunnel will often route Microsoft endpoints directly."
    return @{ ok = $true; ip = $ip }
}

$script:WorkSelfTest = {
    WOut ("PowerShell {0}" -f $PSVersionTable.PSVersion)
    WOut ("Temp folder: {0}" -f $env:TEMP)
    foreach ($e in @('pac','dotnet')) {
        $p = ResolveExe $e
        if ($p) { WOk "$e -> $p"; [void](RunCli -Exe $e -Arguments @('--version') -WorkDir $env:TEMP) }
        else    { WErr "$e NOT found on PATH" }
    }
    WOk "Self-test finished."
    return @{ ok = $true }
}

# ---------------------------------------------------------------------------
# UI actions
# ---------------------------------------------------------------------------
function Invoke-SignIn {
    $name = $ctl.TxtAuthName.Text.Trim()
    if (-not $name)          { Add-Activity 'FAIL' "Give the connection a name."; return }
    if ($name.Length -gt 30) { Add-Activity 'FAIL' "Connection name must be 30 characters or fewer."; return }

    $a = @('auth','create','--name',$name)
    if ($ctl.ChkDeviceCode.IsChecked) { $a += '--deviceCode' }

    Start-Work 'Waiting for sign-in' $script:WorkSignIn @{ AppDir = $script:AppDir; Args = $a } {
        param($r)
        if ($r -and $r.ok) { Get-Environments }
    }
}

function Get-Environments {
    Start-Work 'Loading environments' $script:WorkEnvList @{ AppDir = $script:AppDir } {
        param($r)
        if (-not $r -or -not $r.ok) { return }
        $rows = New-Object 'System.Collections.Generic.List[EnvRow]'
        foreach ($x in @($r.rows)) {
            $e = New-Object EnvRow
            $e.Name = $x.Name; $e.Url = $x.Url; $e.Id = $x.Id
            $rows.Add($e)
        }
        $ctl.LvEnvs.ItemsSource = $rows
        $ctl.TbEnvCount.Text = "$($rows.Count) environment(s)"
    }
}

function Select-Environment {
    $row = $ctl.LvEnvs.SelectedItem
    if (-not $row)                { Add-Activity 'FAIL' "Pick an environment from the list first."; return }
    if (-not (Test-EnvUrl $row.Url)) { return }
    $url = $row.Url; $name = $row.Name
    $done = {
        param($r, $c)
        if ($r -and $r.ok) {
            $script:CurrentEnv = $c.Row
            Update-EnvChip
            Add-Activity 'OK' "Target is now: $($c.Row.Name)"
            Get-Solutions
        }
    }
    Start-Work "Selecting $name" $script:WorkPac `
        @{ AppDir = $script:AppDir; Args = @('env','select','--environment',$url) } $done @{ Row = $row }
}

function Get-Solutions {
    if (-not $script:CurrentEnv) { Add-Activity 'FAIL' "Select an environment first."; return }
    Start-Work 'Loading solutions' $script:WorkSolList `
        @{ AppDir = $script:AppDir; IncludeSystem = [bool]$ctl.ChkSysSolutions.IsChecked } {
        param($r)
        if (-not $r -or -not $r.ok) { return }
        $rows = New-Object 'System.Collections.Generic.List[SolutionRow]'
        foreach ($s in @($r.data)) {
            $o = New-Object SolutionRow
            $o.UniqueName   = Get-Prop $s @('SolutionUniqueName','UniqueName','uniquename','solutionuniquename','Name')
            $o.FriendlyName = Get-Prop $s @('FriendlyName','friendlyname','DisplayName','displayname','SolutionFriendlyName') $o.UniqueName
            $o.Version      = Get-Prop $s @('VersionNumber','Version','version','solutionversion')
            $m              = Get-Prop $s @('IsManaged','Managed','ismanaged','isManaged')
            $o.Managed      = if ($m -match '^(true|1|yes)$') { 'Yes' } elseif ($m) { 'No' } else { '' }
            if ($o.UniqueName) { $rows.Add($o) }
        }
        $sorted = New-Object 'System.Collections.Generic.List[SolutionRow]'
        foreach ($x in ($rows | Sort-Object FriendlyName)) { $sorted.Add($x) }
        $ctl.LvSols.ItemsSource = $sorted
        $ctl.TbSolCount.Text = "$($sorted.Count) solution(s) in $($script:CurrentEnv.Name)"
        if ($sorted.Count -eq 0) { Add-Activity 'OUT' "Tick 'Include system solutions' if you expected more." }
    }
}

function Invoke-ExportSolutions {
    if (-not $script:CurrentEnv) { Add-Activity 'FAIL' "Select an environment first."; return }
    $picked = @()
    foreach ($r in @($ctl.LvSols.ItemsSource)) { if ($r -and $r.Selected) { $picked += $r.UniqueName } }
    if ($picked.Count -eq 0) { Add-Activity 'FAIL' "Tick at least one solution to export."; return }

    $dir = $ctl.TxtExportDir.Text.Trim().TrimEnd('\')
    if (-not $dir) { Add-Activity 'FAIL' "Choose an export folder."; return }
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { Write-Err $_ 'creating export folder'; return }
    }
    $kinds = @()
    if ($ctl.ChkExpManaged.IsChecked)   { $kinds += $true }
    if ($ctl.ChkExpUnmanaged.IsChecked) { $kinds += $false }
    if ($kinds.Count -eq 0) { Add-Activity 'FAIL' "Tick Managed, Unmanaged, or both."; return }

    $toPkg = [bool]$ctl.ChkExpToPackage.IsChecked
    $done = {
        param($r, $c)
        if ($r -and $r.made -and $c.ToPackage) {
            foreach ($f in @($r.made)) {
                if (-not $ctl.LstSolutions.Items.Contains($f)) { [void]$ctl.LstSolutions.Items.Add($f) }
            }
            Add-Activity 'OK' "added $(@($r.made).Count) file(s) to the Create Package list"
            Save-Settings
        }
    }
    Start-Work "Exporting $($picked.Count) solution(s)" $script:WorkExport `
        @{ AppDir = $script:AppDir; Dir = $dir; Solutions = $picked; Kinds = $kinds } $done @{ ToPackage = $toPkg }
}

function Invoke-ImportSolution {
    if (-not $script:CurrentEnv) { Add-Activity 'FAIL' "Select an environment first."; return }
    $zip = $ctl.TxtImportZip.Text.Trim().Trim('"')
    if (-not $zip)                          { Add-Activity 'FAIL' "Choose a solution zip."; return }
    if (-not (Test-Path -LiteralPath $zip)) { Add-Activity 'FAIL' "Not found: $zip"; return }

    $r = [System.Windows.MessageBox]::Show(
        "Import this solution into $($script:CurrentEnv.Name)?`r`n`r`n$(Split-Path -Leaf $zip)`r`n$($script:CurrentEnv.Url)",
        'Confirm import', 'OKCancel', 'Warning')
    if ($r -ne 'OK') { Add-Activity 'WARN' "Import cancelled."; return }

    Start-Work "Importing $(Split-Path -Leaf $zip)" $script:WorkImport @{
        AppDir = $script:AppDir; Zip = $zip
        Publish  = [bool]$ctl.ChkImpPublish.IsChecked
        Activate = [bool]$ctl.ChkImpActivate.IsChecked
        Force    = [bool]$ctl.ChkImpForce.IsChecked
        Upgrade  = [bool]$ctl.ChkImpUpgrade.IsChecked
    } { param($res) if ($res -and $res.ok) { Get-Solutions } }
}

function Invoke-CreatePackage {
    $name = $ctl.TxtPkgName.Text.Trim()
    $out  = $ctl.TxtOutDir.Text.Trim().TrimEnd('\')
    $sols = @($ctl.LstSolutions.Items | ForEach-Object { [string]$_ })

    if (-not $name)                         { Add-Activity 'FAIL' "Package name is required."; return }
    if ($name -match '[\\/:*?"<>|\s]')      { Add-Activity 'FAIL' "Package name cannot contain spaces or \ / : * ? < > |"; return }
    if (-not $out)                          { Add-Activity 'FAIL' "Output folder is required."; return }
    if (-not (Test-Path -LiteralPath $out)) { Add-Activity 'FAIL' "Output folder does not exist: $out"; return }
    if ($sols.Count -eq 0)                  { Add-Activity 'FAIL' "Add at least one solution zip."; return }

    $proj = Join-Path $out $name
    $wipe = $false
    if (Test-Path -LiteralPath $proj) {
        if (-not (Test-InsidePath $proj $out)) { Add-Activity 'FAIL' "Unsafe project path: $proj"; return }
        $r = [System.Windows.MessageBox]::Show("'$proj' already exists.`r`n`r`nDelete it and start fresh?",
             'Package Deployer Studio', 'YesNoCancel', 'Warning')
        if ($r -eq 'Cancel') { Add-Activity 'WARN' "Cancelled."; return }
        if ($r -eq 'Yes')    { $wipe = $true }
    }

    Start-Work "Creating package $name" $script:WorkCreatePackage `
        @{ Name = $name; OutDir = $out; Solutions = $sols; Wipe = $wipe } {
        param($r)
        if (-not $r -or -not $r.ok) { return }
        $script:LastBuiltDir = $r.dir
        $script:LastBuilt    = if ($r.zip) { $r.zip } else { $r.dir }
        if ($r.dir) { $ctl.TxtPkg.Text = $r.dir } else { $ctl.TxtPkg.Text = $script:LastBuilt }
        $ctl.TxtDeployPkg.Text = $script:LastBuilt
        Add-Activity 'OK' "Deploy page is now pointed at this build."
        Save-Settings
    }
}

$script:DoneStep = {
    param($r, $c)
    Update-State
    if ($r -and $r.ok -and $c.Then) { & $c.Then }
}

function Invoke-Clean {
    param([scriptblock]$Then = $null)
    if (-not (Test-ToolDir)) { return }
    Start-Work 'Cleaning the tool folder' $script:WorkClean @{
        ToolDir = (Get-ToolDir); BaselineFile = $script:BaselineFile
        ProtectedRegex = $script:ProtectedRegex; DeleteTokens = [bool]$ctl.ChkTokens.IsChecked
        ProfileDir = $script:DeployerProfileDir
    } $script:DoneStep @{ Then = $Then }
}

function Clear-DeployerSignIn {
    <#
      Make Package Deployer ask for an account and environment again.

      Deleting the token file alone is not enough - Default_PackageDeployer.exe.config
      holds the last connection, so the tool would still preselect the previous
      environment. Both go; the log files stay.
    #>
    Add-Activity 'STEP' 'Forget the Package Deployer sign-in'
    $profileDir = $script:DeployerProfileDir
    $tool       = Get-ToolDir
    $removed    = 0

    $targets = @()
    if ($tool) { $targets += (Join-Path $tool 'PackageDeployer.tokens.dat') }
    if (Test-Path -LiteralPath $profileDir) {
        $targets += @(Get-ChildItem -LiteralPath $profileDir -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like '*.tokens.dat' -or $_.Name -like '*.exe.config' } |
                      ForEach-Object { $_.FullName })
    }

    foreach ($f in $targets) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $inProfile = Test-InsidePath $f $profileDir
        $inTool    = $tool -and (Test-InsidePath $f $tool)
        if (-not ($inProfile -or $inTool)) { continue }     # containment guard
        try {
            Remove-Item -LiteralPath $f -Force
            Add-Activity 'OK' "forgot $(Split-Path -Leaf $f)"
            $removed++
        } catch {
            Add-Activity 'FAIL' "could not remove $(Split-Path -Leaf $f) - close Package Deployer first"
        }
    }

    if ($removed -eq 0) {
        Add-Activity 'OK' "Nothing cached - Package Deployer will ask on the next run."
    } else {
        Add-Activity 'OK' "Cleared $removed file(s). Package Deployer will ask for an account and environment next time."
    }
    Add-Activity 'OUT' "Cache location: $profileDir"
}

function Invoke-Load {
    param([scriptblock]$Then = $null)
    if (-not (Test-ToolDir)) { return }
    $src = $ctl.TxtPkg.Text.Trim().Trim('"')
    if (-not $src)                          { Add-Activity 'FAIL' "No package selected."; return }
    if (-not (Test-Path -LiteralPath $src)) { Add-Activity 'FAIL' "Not found: $src"; return }
    $flag = Join-Path $script:StateDir 'unblocked.flag'
    $full = -not (Test-Path -LiteralPath $flag)
    $done = {
        param($r, $c)
        Update-State
        if ($r -and $r.ok) {
            try { 'done' | Set-Content -LiteralPath $c.Flag -Encoding UTF8 } catch { }
            if ($c.Then) { & $c.Then }
        }
    }
    Start-Work 'Loading the package' $script:WorkLoad @{
        ToolDir = (Get-ToolDir); Source = $src; BaselineFile = $script:BaselineFile
        ProtectedRegex = $script:ProtectedRegex; FullUnblock = $full
    } $done @{ Then = $Then; Flag = $flag }
}

function Invoke-Verify {
    param([scriptblock]$Then = $null)
    if (-not (Test-ToolDir)) { return }
    Start-Work 'Verifying the tool folder' $script:WorkVerify @{
        ToolDir = (Get-ToolDir); BaselineFile = $script:BaselineFile; ProtectedRegex = $script:ProtectedRegex
    } $script:DoneStep @{ Then = $Then }
}

function Invoke-Launch {
    if (-not (Test-ToolDir)) { return }
    try {
        Start-Process -FilePath (Join-Path (Get-ToolDir) 'PackageDeployer.exe') -WorkingDirectory (Get-ToolDir)
        Add-Activity 'OK' "PackageDeployer.exe started. Large packages take 45-120 minutes."
        $cached = @(Get-ChildItem -LiteralPath $script:DeployerProfileDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*.tokens.dat' })
        if ($cached.Count -gt 0) {
            Add-Activity 'WARN' "A cached sign-in exists, so it may not ask for an account or environment."
            Add-Activity 'OUT'  "Close it, click 'Forget sign-in', and launch again to be prompted."
        }
    } catch { Write-Err $_ 'starting the tool' }
}

function Invoke-CliDeploy {
    $pkg = $ctl.TxtDeployPkg.Text.Trim().Trim('"')
    if (-not $pkg)                          { Add-Activity 'FAIL' "No package selected."; return }
    if (-not (Test-Path -LiteralPath $pkg)) { Add-Activity 'FAIL' "Not found: $pkg"; return }
    if (-not $script:CurrentEnv) {
        Add-Activity 'FAIL' "Connect to an environment first (Environment page)."
        return
    }
    $r = [System.Windows.MessageBox]::Show(
        "Deploy this package?`r`n`r`n$pkg`r`n`r`nTarget:`r`n$($script:CurrentEnv.Name)`r`n$($script:CurrentEnv.Url)`r`n`r`nLarge packages take 45-120 minutes.",
        'Confirm deployment', 'OKCancel', 'Warning')
    if ($r -ne 'OK') { Add-Activity 'WARN' "Deployment cancelled."; return }

    $log = Join-Path $script:LogDir ('deploy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Add-Activity 'OUT' "deploy log: $log"
    Start-Work 'Deploying package' $script:WorkDeploy @{ AppDir = $script:AppDir; Package = $pkg; LogFile = $log }
}

function Save-Baseline {
    if (-not (Test-ToolDir)) { return }
    $t = Get-ToolDir
    $assets = Get-AssetFolders -Root $t
    if ($assets.Count -gt 0) {
        $names = ($assets | ForEach-Object { $_.Name }) -join ', '
        $r = [System.Windows.MessageBox]::Show(
            "A package looks like it is already loaded (found: $names).`r`n`r`nSnapshot anyway? Those files would then be treated as part of the tool and never cleaned.",
            'Package Deployer Studio', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { Add-Activity 'WARN' "Snapshot cancelled."; return }
    }
    $files = Get-ChildItem -LiteralPath $t -File      | ForEach-Object { $_.Name }
    $dirs  = Get-ChildItem -LiteralPath $t -Directory | ForEach-Object { 'DIR:' + $_.Name }
    @($files + $dirs) | Sort-Object | Set-Content -LiteralPath $script:BaselineFile -Encoding UTF8
    $script:BaselineCache = $null
    Add-Activity 'OK' "Baseline saved: $($files.Count) files, $($dirs.Count) folders."
    Update-State
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
function Save-Settings {
    # Nothing secret is ever written here - auth lives in the PAC CLI's own store.
    try {
        [pscustomobject]@{
            ToolDir   = $ctl.TxtTool.Text
            PkgSource = $ctl.TxtPkg.Text
            OutDir    = $ctl.TxtOutDir.Text
            PkgName   = $ctl.TxtPkgName.Text
            AuthName  = $ctl.TxtAuthName.Text
            ExportDir = $ctl.TxtExportDir.Text
            DeployPkg = $ctl.TxtDeployPkg.Text
            Solutions = @($ctl.LstSolutions.Items | ForEach-Object { [string]$_ })
            Theme     = $script:Theme
            Sidebar   = $script:SidebarOpen
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
    } catch { }
}

function Import-Settings {
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) { return }
    try {
        $s = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
        if ($s.ToolDir)   { $ctl.TxtTool.Text      = $s.ToolDir }
        if ($s.PkgSource) { $ctl.TxtPkg.Text       = $s.PkgSource }
        if ($s.OutDir)    { $ctl.TxtOutDir.Text    = $s.OutDir }
        if ($s.PkgName)   { $ctl.TxtPkgName.Text   = $s.PkgName }
        if ($s.AuthName)  { $ctl.TxtAuthName.Text  = $s.AuthName }
        if ($s.ExportDir) { $ctl.TxtExportDir.Text = $s.ExportDir }
        if ($s.DeployPkg) { $ctl.TxtDeployPkg.Text = $s.DeployPkg }
        if ($s.Solutions) { foreach ($x in $s.Solutions) { if ($x) { [void]$ctl.LstSolutions.Items.Add($x) } } }
        if ($s.RegionUrl) { $script:RegionUrl = [string]$s.RegionUrl }
        if ($s.Theme -in @('Light','Dark')) { $script:Theme = $s.Theme }
        if ($null -ne $s.Sidebar) { $script:SidebarOpen = [bool]$s.Sidebar }
    } catch { }
}

# ---------------------------------------------------------------------------
# Navigation & chrome
# ---------------------------------------------------------------------------
$script:Pages = @(
    @{ Key='PageCreate'; Title='Create Package'; Sub='Build a Package Deployer package from solution zips.' },
    @{ Key='PageDeploy'; Title='Deploy';         Sub='Deploy with the CLI, or drive the Package Deployer GUI tool.' },
    @{ Key='PageEnv';    Title='Environment';    Sub='Sign in, then pick the environment you want to work against.' },
    @{ Key='PageSol';    Title='Solutions';      Sub='Browse, export and import solutions in the selected environment.' }
)

function Show-Page {
    param([int]$Index)
    if ($Index -lt 0 -or $Index -ge $script:Pages.Count) { return }
    for ($i = 0; $i -lt $script:Pages.Count; $i++) {
        $ctl[$script:Pages[$i].Key].Visibility = if ($i -eq $Index) { 'Visible' } else { 'Collapsed' }
    }
    $ctl.TbPageTitle.Text = $script:Pages[$Index].Title
    $ctl.TbPageSub.Text   = $script:Pages[$Index].Sub
}

function Set-Sidebar {
    param([bool]$Open)
    $script:SidebarOpen = $Open
    $ctl.ColSidebar.Width = if ($Open) { [System.Windows.GridLength]::new(232) } else { [System.Windows.GridLength]::new(62) }
    $v = if ($Open) { 'Visible' } else { 'Collapsed' }
    foreach ($n in @('BrandBox','EnvBox','NavLbl0','NavLbl1','NavLbl2','NavLbl3')) { $ctl[$n].Visibility = $v }
}

function Set-LogPanel {
    param([bool]$Open)
    $script:LogOpen = $Open
    $ctl.LogHost.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    $ctl.RowLog.Height = if ($Open) { [System.Windows.GridLength]::new(240) } else { [System.Windows.GridLength]::Auto }
    $ctl.IcLogChevron.Data = [System.Windows.Media.Geometry]::Parse(
        $(if ($Open) { 'M4,12 L10,6 L16,12' } else { 'M4,8 L10,14 L16,8' }))
}

# ---------------------------------------------------------------------------
# Wire up
# ---------------------------------------------------------------------------
$ctl.Nav.Add_SelectionChanged({ Show-Page $ctl.Nav.SelectedIndex })
$ctl.BtnBurger.Add_Click({ Set-Sidebar (-not $script:SidebarOpen); Save-Settings })
$ctl.BtnTheme.Add_Click({ Set-Theme $(if ($script:Theme -eq 'Light') { 'Dark' } else { 'Light' }); Save-Settings })
$ctl.BtnLogToggle.Add_Click({ Set-LogPanel (-not $script:LogOpen) })
$ctl.CmbFilter.Add_SelectionChanged({ Sync-ActivityView })

# Create Package
$ctl.BtnBuild.Add_Click({ Invoke-CreatePackage })
$ctl.BtnOutBrowse.Add_Click({
    $p = Select-FolderDialog -Description 'Where should the package project be created?' -Start $ctl.TxtOutDir.Text
    if ($p) { $ctl.TxtOutDir.Text = $p; Save-Settings }
})
$ctl.BtnSolAdd.Add_Click({
    $f = Select-FileDialog -Title 'Select solution zip files' -Filter 'Solution (*.zip)|*.zip' -Multi -Start $ctl.TxtExportDir.Text
    foreach ($x in $f) { if (-not $ctl.LstSolutions.Items.Contains($x)) { [void]$ctl.LstSolutions.Items.Add($x) } }
    Save-Settings
})
$ctl.BtnSolUp.Add_Click({
    $i = $ctl.LstSolutions.SelectedIndex
    if ($i -gt 0) {
        $v = $ctl.LstSolutions.Items[$i]; $ctl.LstSolutions.Items.RemoveAt($i)
        $ctl.LstSolutions.Items.Insert($i-1, $v); $ctl.LstSolutions.SelectedIndex = $i-1; Save-Settings
    }
})
$ctl.BtnSolDown.Add_Click({
    $i = $ctl.LstSolutions.SelectedIndex
    if ($i -ge 0 -and $i -lt $ctl.LstSolutions.Items.Count-1) {
        $v = $ctl.LstSolutions.Items[$i]; $ctl.LstSolutions.Items.RemoveAt($i)
        $ctl.LstSolutions.Items.Insert($i+1, $v); $ctl.LstSolutions.SelectedIndex = $i+1; Save-Settings
    }
})
$ctl.BtnSolDel.Add_Click({
    $i = $ctl.LstSolutions.SelectedIndex
    if ($i -ge 0) { $ctl.LstSolutions.Items.RemoveAt($i); Save-Settings }
})
$ctl.BtnSolClear.Add_Click({ $ctl.LstSolutions.Items.Clear(); Save-Settings })
$ctl.BtnOpenOut.Add_Click({
    $p = $ctl.TxtOutDir.Text.Trim()
    if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe $p }
})
$ctl.BtnUseInDeploy.Add_Click({
    if ($script:LastBuilt) { $ctl.TxtDeployPkg.Text = $script:LastBuilt; $ctl.Nav.SelectedIndex = 1; Save-Settings }
    else { Add-Activity 'WARN' "Nothing has been built in this session yet." }
})

# Deploy
$ctl.BtnCliDeploy.Add_Click({ Invoke-CliDeploy })
$ctl.BtnClean.Add_Click({  Invoke-Clean })
$ctl.BtnLoad.Add_Click({   Invoke-Load })
$ctl.BtnVerify.Add_Click({ Invoke-Verify })
$ctl.BtnLaunch.Add_Click({ Invoke-Launch })
$ctl.BtnBaseline.Add_Click({ Save-Baseline })
$ctl.BtnAll.Add_Click({
    # Chained through the completion callbacks, so each step waits for the last.
    Invoke-Clean {
        Invoke-Load {
            Invoke-Verify {
                if ($ctl.ChkAutoLaunch.IsChecked) { Invoke-Launch }
                else { Add-Activity 'OK' "All checks passed. Click '4. Launch' when ready." }
            }
        }
    }
})
$ctl.BtnToolBrowse.Add_Click({
    $p = Select-FolderDialog -Description "Locate the folder containing PackageDeployer.exe" -Start (Get-ToolDir)
    if (-not $p) { return }
    $ctl.TxtTool.Text = $p
    if (Test-IsToolFolder $p) { Add-Activity 'OK' "Tool folder set: $p" }
    else { Add-Activity 'FAIL' "PackageDeployer.exe is not in that folder. Pick the folder that contains it." }
    Update-ToolBanner; Update-State; Save-Settings
})
$ctl.BtnPkgFolder.Add_Click({
    $p = Select-FolderDialog -Description 'Select the package publish folder' -Start $ctl.TxtPkg.Text
    if ($p) { $ctl.TxtPkg.Text = $p; Show-PackageSummary $p 'Package'; Save-Settings }
})
$ctl.BtnPkgZip.Add_Click({
    $f = Select-FileDialog -Title 'Select the package zip (.pdpkg.zip)' -Filter 'Package Deployer package (*.zip)|*.zip|All files (*.*)|*.*' -Start $ctl.TxtPkg.Text
    if ($f -and $f.Count -gt 0) { $ctl.TxtPkg.Text = $f[0]; Show-PackageSummary $f[0] 'Package'; Save-Settings }
})
$ctl.BtnDeployZip.Add_Click({
    $f = Select-FileDialog -Title 'Select the package zip (.pdpkg.zip)' -Filter 'Package Deployer package (*.zip)|*.zip|All files (*.*)|*.*' -Start $ctl.TxtDeployPkg.Text
    if ($f -and $f.Count -gt 0) { $ctl.TxtDeployPkg.Text = $f[0]; Show-PackageSummary $f[0] 'Package'; Save-Settings }
})
$ctl.BtnDeployFolder.Add_Click({
    $p = Select-FolderDialog -Description 'Select the folder holding the package' -Start $ctl.TxtDeployPkg.Text
    if (-not $p) { return }
    # 'pac package deploy --package' wants a package zip or the package .dll,
    # not a folder - so resolve the folder down to the right file.
    $pick = $null
    $zip = @(Get-ChildItem -LiteralPath $p -Recurse -File -Filter '*.pdpkg.zip' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($zip.Count -gt 0) { $pick = $zip[0].FullName }
    else {
        $dll = @(Get-ChildItem -LiteralPath $p -File -Filter *.dll -ErrorAction SilentlyContinue |
                 Where-Object { $_.BaseName -notmatch $script:ProtectedRegex } | Select-Object -First 1)
        if ($dll.Count -gt 0) { $pick = $dll[0].FullName }
    }
    if ($pick) {
        $ctl.TxtDeployPkg.Text = $pick
        Add-Activity 'OK' "Found the package in that folder: $(Split-Path -Leaf $pick)"
        Show-PackageSummary $pick 'Package'
    } else {
        $ctl.TxtDeployPkg.Text = $p
        Add-Activity 'WARN' "No .pdpkg.zip or package .dll in that folder - the CLI needs one of those."
        Show-PackageSummary $p 'Package'
    }
    Save-Settings
})
$ctl.BtnDeployLogs.Add_Click({ if (Test-Path -LiteralPath $script:LogDir) { Start-Process explorer.exe $script:LogDir } })
$ctl.BtnForget.Add_Click({
    if ($script:Busy) { Add-Activity 'WARN' "Wait for the current job to finish."; return }
    try { Clear-DeployerSignIn } catch { Write-Err $_ 'forgetting the sign-in' }
})
$ctl.BtnOpenPdCache.Add_Click({
    if (Test-Path -LiteralPath $script:DeployerProfileDir) { Start-Process explorer.exe $script:DeployerProfileDir }
    else { Add-Activity 'WARN' "Nothing there yet: $script:DeployerProfileDir" }
})

# Environment
$ctl.BtnSignIn.Add_Click({ Invoke-SignIn })
$ctl.BtnAuthList.Add_Click({ Start-Work 'Listing saved connections' $script:WorkPac @{ AppDir = $script:AppDir; Args = @('auth','list') } })
$ctl.BtnAuthSelect.Add_Click({
    $n = $ctl.TxtAuthName.Text.Trim()
    if (-not $n) { Add-Activity 'FAIL' "Enter the connection name to switch to."; return }
    Start-Work "Switching to $n" $script:WorkPac @{ AppDir = $script:AppDir; Args = @('auth','select','--name',$n) } {
        param($r) if ($r -and $r.ok) { Get-Environments }
    }
})
$ctl.BtnSignOut.Add_Click({
    $r = [System.Windows.MessageBox]::Show("Remove every saved Power Platform connection from this computer?",
         'Package Deployer Studio', 'YesNo', 'Warning')
    if ($r -ne 'Yes') { return }
    Start-Work 'Clearing connections' $script:WorkPac @{ AppDir = $script:AppDir; Args = @('auth','clear') } {
        param($res)
        $script:CurrentEnv = $null
        $ctl.LvEnvs.ItemsSource = $null
        $ctl.LvSols.ItemsSource = $null
        Update-EnvChip
    }
})
$ctl.BtnEnvRefresh.Add_Click({ Get-Environments })
$ctl.BtnEnvSelect.Add_Click({ Select-Environment })
$ctl.LvEnvs.Add_MouseDoubleClick({ Select-Environment })
$ctl.BtnWhoAmI.Add_Click({ Start-Work 'Checking the current target' $script:WorkPac @{ AppDir = $script:AppDir; Args = @('env','who') } })

# Solutions
$ctl.BtnSolRefresh.Add_Click({ Get-Solutions })
$ctl.BtnExport.Add_Click({ Invoke-ExportSolutions })
$ctl.BtnImport.Add_Click({ Invoke-ImportSolution })
$ctl.BtnSolAll.Add_Click({  foreach ($r in @($ctl.LvSols.ItemsSource)) { if ($r) { $r.Selected = $true } } })
$ctl.BtnSolNone.Add_Click({ foreach ($r in @($ctl.LvSols.ItemsSource)) { if ($r) { $r.Selected = $false } } })
$ctl.BtnExportDir.Add_Click({
    $p = Select-FolderDialog -Description 'Where should exported solutions go?' -Start $ctl.TxtExportDir.Text
    if ($p) { $ctl.TxtExportDir.Text = $p; Save-Settings }
})
$ctl.BtnOpenExport.Add_Click({
    $p = $ctl.TxtExportDir.Text.Trim()
    if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe $p } else { Add-Activity 'WARN' "Export folder not found." }
})
$ctl.BtnImportPick.Add_Click({
    $f = Select-FileDialog -Title 'Select a solution zip' -Filter 'Solution (*.zip)|*.zip' -Start $ctl.TxtExportDir.Text
    if ($f -and $f.Count -gt 0) { $ctl.TxtImportZip.Text = $f[0]; Save-Settings }
})

# Activity toolbar
$ctl.BtnSelfTest.Add_Click({
    Add-Activity 'OUT' ("Theme {0} / sidebar {1} / STA {2}" -f $script:Theme, $script:SidebarOpen,
                        ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'))
    if (Test-ToolDir) { Add-Activity 'OK' "tool folder OK" }
    if (Test-Path -LiteralPath $script:BaselineFile) { Add-Activity 'OK' "baseline: $((Read-Baseline).Count) entries" }
    else { Add-Activity 'WARN' "baseline not recorded" }
    Start-Work 'Running self-test' $script:WorkSelfTest @{}
})
$ctl.BtnRegion.Add_Click({
    $cfg = $script:RegionUrl
    Add-Activity 'OUT' "Region check contacts an external service to learn your public IP."
    Start-Work 'Checking the outbound region' $script:WorkRegion @{ Url = $cfg }
})

$ctl.BtnOpenLogs.Add_Click({
    $p = Join-Path $env:APPDATA 'Microsoft\PackageDeployer'
    if (Test-Path -LiteralPath $p) { Start-Process explorer.exe $p } else { Add-Activity 'WARN' "No Package Deployer logs yet." }
})
$ctl.BtnSaveLog.Add_Click({
    $f = Join-Path $script:LogDir ('studio-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $script:RawLog.ToString() | Set-Content -LiteralPath $f -Encoding UTF8
    Add-Activity 'OK' "log saved to $f"
})
$ctl.BtnClearLog.Add_Click({
    $script:AllActivity.Clear(); $script:View.Clear()
    [void]$script:RawLog.Clear(); $ctl.TbLastStatus.Text = ''
})

$win.Add_Closing({
    # PowerShell passes (sender, eventArgs) positionally to event handlers;
    # $_ is not bound here, so take the args explicitly.
    param($eventSender, $e)
    if ($script:Busy) {
        $r = [System.Windows.MessageBox]::Show(
            "'$($script:BusyTitle)' is still running.`r`n`r`nClose anyway? The background command may keep running.",
            'Package Deployer Studio', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { if ($e) { $e.Cancel = $true }; return }
    }
    try { $script:Timer.Stop() } catch { }
    if ($script:Job) { try { $script:Job.PS.Dispose(); $script:Job.RS.Dispose() } catch { } }
    Save-Settings
})

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
$ctl.TbVersion.Text    = "v$script:AppVersion"
$ctl.TxtTool.Text      = $script:ToolDir
$ctl.TxtOutDir.Text    = $script:AppDir
$ctl.TxtExportDir.Text = $script:ExportDir
Import-Settings
Set-Theme $script:Theme
Set-Sidebar $script:SidebarOpen
Set-LogPanel $true
Update-EnvChip
Show-Page 0
$ctl.Nav.SelectedIndex = 0

Add-Activity 'OK'  "Package Deployer Studio v$script:AppVersion ready."
Add-Activity 'OUT' "Working folder: $script:AppDir"
Initialize-ToolFolder
if ((Test-IsToolFolder (Get-ToolDir)) -and -not (Test-Path -LiteralPath $script:BaselineFile)) {
    Add-Activity 'OUT' "Tip: on the Deploy page, click Snapshot once while the tool folder is clean."
}
Update-State

[void]$win.ShowDialog()
