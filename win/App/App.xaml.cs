using System.Windows;
using System.Windows.Threading;

namespace SeekIRWin.App;

/// <summary>
/// Interaction logic for App.xaml
/// </summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Глобальная граница исключений: один битый кадр/USB-глюк не должен ронять
        // процесс без диагностики — пишем в error.log и держим приложение (для
        // устройства с reconnect-логикой пережить глюк важнее, чем упасть чисто).
        DispatcherUnhandledException += (_, a) =>
        {
            Diag.Log("Dispatcher: " + a.Exception);
            a.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, a) =>
            Diag.Log("AppDomain: " + (a.ExceptionObject?.ToString() ?? "(no exception)"));
        TaskScheduler.UnobservedTaskException += (_, a) =>
        { Diag.Log("UnobservedTask: " + a.Exception); a.SetObserved(); };

        base.OnStartup(e);
        WindowTheme.HookAllWindows();
    }
}
