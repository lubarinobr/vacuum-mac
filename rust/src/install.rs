//! Runs vacuumd in the background at login: a launch agent on macOS, a scheduled task on Windows,
//! a systemd user service on Linux.
use crate::config;
use std::path::PathBuf;
use std::process::Command;

fn installed_binary() -> PathBuf {
    let name = if cfg!(windows) { "vacuumd.exe" } else { "vacuumd" };
    config::data_dir().join("bin").join(name)
}

fn log_path() -> PathBuf {
    config::data_dir().join("vacuumd.log")
}

fn run(program: &str, args: &[&str]) -> bool {
    Command::new(program).args(args).status().map(|s| s.success()).unwrap_or(false)
}

/// Makes `vacuumd` typeable in any terminal. Returns a note to show the user.
/// macOS/Linux: a link in a folder under your home that is already on the PATH (else ~/.local/bin).
/// Windows: adds the program's folder to your user PATH.
pub fn add_to_path() -> String {
    let binary = installed_binary();
    #[cfg(unix)]
    {
        let Some(home) = dirs::home_dir() else { return String::new() };
        let on_path: Vec<PathBuf> = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
        let preferred = [home.join(".local/bin"), home.join("bin")];
        let (folder, already) = match preferred.iter().find(|p| on_path.contains(p)) {
            Some(found) => (found.clone(), true),
            None => (preferred[0].clone(), false),
        };
        let link = folder.join("vacuumd");
        let linked = std::fs::create_dir_all(&folder).is_ok() && {
            let _ = std::fs::remove_file(&link); // replaces an older link, never a real folder
            std::os::unix::fs::symlink(&binary, &link).is_ok()
        };
        return match (linked, already) {
            (true, true) => format!("You can now type `vacuumd` in any new terminal ({}).", link.display()),
            (true, false) => format!("Linked {}. Add it to your PATH to type `vacuumd` anywhere: export PATH=\"{}:$PATH\"", link.display(), folder.display()),
            (false, _) => format!("Couldn't link {}; run the program by its full path: {}", link.display(), binary.display()),
        };
    }
    #[cfg(windows)]
    {
        let dir = binary.parent().unwrap().to_string_lossy().to_string();
        let script = format!(
            "$p=[Environment]::GetEnvironmentVariable('Path','User'); if (($p -split ';') -notcontains '{dir}') {{ [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ';{dir}'), 'User') }}"
        );
        return if run("powershell.exe", &["-NoProfile", "-Command", &script]) {
            "You can now type `vacuumd` in any NEW terminal window.".to_string()
        } else {
            format!("Couldn't change your PATH; run the program by its full path: {}", binary.display())
        };
    }
}

fn remove_from_path() {
    #[cfg(unix)]
    if let Some(home) = dirs::home_dir() {
        for folder in [home.join(".local/bin"), home.join("bin")] {
            let link = folder.join("vacuumd");
            // only our own link: never a different program that happens to share the name
            if std::fs::read_link(&link).map_or(false, |target| target == installed_binary()) {
                let _ = std::fs::remove_file(&link);
            }
        }
    }
    #[cfg(windows)]
    {
        let dir = installed_binary().parent().unwrap().to_string_lossy().to_string();
        let script = format!(
            "$p=[Environment]::GetEnvironmentVariable('Path','User'); [Environment]::SetEnvironmentVariable('Path', (($p -split ';' | Where-Object {{ $_ -ne '{dir}' }}) -join ';'), 'User')"
        );
        run("powershell.exe", &["-NoProfile", "-Command", &script]);
    }
}

pub fn install(port: u16) -> Result<PathBuf, String> {
    let target = installed_binary();
    // Copy the binary somewhere stable, so rebuilding or moving the download never changes what runs at login.
    let current = std::env::current_exe().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(target.parent().unwrap()).map_err(|e| e.to_string())?;
    if current != target {
        let _ = std::fs::remove_file(&target);
        std::fs::copy(&current, &target).map_err(|e| format!("couldn't copy the program: {e}"))?;
    }
    let (binary, log) = (target.to_string_lossy().to_string(), log_path().to_string_lossy().to_string());

    #[cfg(target_os = "macos")]
    {
        let home = dirs::home_dir().ok_or("no home folder")?;
        let plist = home.join("Library/LaunchAgents/com.lubarino.vacuumd.plist");
        let contents = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.lubarino.vacuumd</string>
<key>ProgramArguments</key><array><string>{binary}</string><string>serve</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>{log}</string><key>StandardErrorPath</key><string>{log}</string>
<key>EnvironmentVariables</key><dict><key>VACUUMD_PORT</key><string>{port}</string></dict>
</dict></plist>
"#
        );
        std::fs::create_dir_all(plist.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(&plist, contents).map_err(|e| e.to_string())?;
        let domain = format!("gui/{}", unsafe_uid());
        run("launchctl", &["bootout", &format!("{domain}/com.lubarino.vacuumd")]);
        if !run("launchctl", &["bootstrap", &domain, &plist.to_string_lossy()]) {
            return Err(format!("launchctl couldn't load {}", plist.display()));
        }
    }
    #[cfg(target_os = "windows")]
    {
        // Starts hidden at every login of this user; no administrator rights needed.
        let command = format!("powershell.exe -WindowStyle Hidden -Command \"$env:VACUUMD_PORT='{port}'; & '{binary}' serve *> '{log}'\"");
        if !run("schtasks", &["/Create", "/TN", "Vacuumd", "/SC", "ONLOGON", "/TR", &command, "/RL", "LIMITED", "/F"]) {
            return Err("schtasks couldn't create the Vacuumd task".into());
        }
        run("schtasks", &["/End", "/TN", "Vacuumd"]);
        run("schtasks", &["/Run", "/TN", "Vacuumd"]);
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        let unit_dir = dirs::config_dir().ok_or("no config folder")?.join("systemd/user");
        std::fs::create_dir_all(&unit_dir).map_err(|e| e.to_string())?;
        let unit = format!(
            "[Unit]\nDescription=Vacuum robot server (MCP)\nAfter=network-online.target\n\n[Service]\nEnvironment=VACUUMD_PORT={port}\nExecStart={binary} serve\nRestart=always\nStandardOutput=append:{log}\nStandardError=append:{log}\n\n[Install]\nWantedBy=default.target\n"
        );
        std::fs::write(unit_dir.join("vacuumd.service"), unit).map_err(|e| e.to_string())?;
        run("systemctl", &["--user", "daemon-reload"]);
        if !run("systemctl", &["--user", "enable", "--now", "vacuumd.service"]) {
            return Err("systemctl couldn't start the vacuumd service".into());
        }
    }
    Ok(target)
}

pub fn uninstall() {
    remove_from_path();
    #[cfg(target_os = "macos")]
    {
        run("launchctl", &["bootout", &format!("gui/{}/com.lubarino.vacuumd", unsafe_uid())]);
        if let Some(home) = dirs::home_dir() {
            let _ = std::fs::remove_file(home.join("Library/LaunchAgents/com.lubarino.vacuumd.plist"));
        }
    }
    #[cfg(target_os = "windows")]
    {
        run("schtasks", &["/End", "/TN", "Vacuumd"]);
        run("schtasks", &["/Delete", "/TN", "Vacuumd", "/F"]);
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        run("systemctl", &["--user", "disable", "--now", "vacuumd.service"]);
        if let Some(dir) = dirs::config_dir() {
            let _ = std::fs::remove_file(dir.join("systemd/user/vacuumd.service"));
        }
    }
    // On Windows the running copy can't delete itself; it's left in place (it is only a few MB).
    let _ = std::fs::remove_file(installed_binary());
}

#[cfg(target_os = "macos")]
fn unsafe_uid() -> String {
    Command::new("id").arg("-u").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_else(|_| "501".into())
}

/// Whether vacuumd is registered to start at login.
pub fn starts_at_login() -> bool {
    #[cfg(target_os = "macos")]
    return dirs::home_dir().map_or(false, |h| h.join("Library/LaunchAgents/com.lubarino.vacuumd.plist").exists());
    #[cfg(target_os = "windows")]
    return Command::new("schtasks").args(["/Query", "/TN", "Vacuumd"]).output().map(|o| o.status.success()).unwrap_or(false);
    #[cfg(all(unix, not(target_os = "macos")))]
    return Command::new("systemctl").args(["--user", "is-enabled", "vacuumd.service"]).output().map(|o| o.status.success()).unwrap_or(false);
}
