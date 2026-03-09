use tauri::{
    menu::{Menu, MenuItem},
    tray::TrayIconBuilder,
    App, Manager,
};

pub fn setup_tray(app: &App) -> Result<(), Box<dyn std::error::Error>> {
    let show = MenuItem::with_id(app, "show", "Show Window", true, None::<&str>)?;
    let restart = MenuItem::with_id(app, "restart_phoenix", "Restart Server", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Symphony", true, None::<&str>)?;

    let menu = Menu::with_items(app, &[&show, &restart, &quit])?;

    TrayIconBuilder::new()
        .menu(&menu)
        .tooltip("Symphony — Running")
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "restart_phoenix" => {
                let _ = super::phoenix::restart(app);
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.eval("location.reload()");
                }
            }
            "quit" => {
                app.exit(0);
            }
            _ => {}
        })
        .build(app)?;

    Ok(())
}
