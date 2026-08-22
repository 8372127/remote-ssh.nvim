local M = {}

local windows_cmd = {
    '@echo off',
    'setlocal',
    'set "REMOTE_SSH_ASKPASS_OUTPUT=%TEMP%\\remote-ssh-askpass-%RANDOM%-%RANDOM%.txt"',
    'powershell.exe -NoProfile -ExecutionPolicy Bypass '
        .. '-File "%~dp0remote-ssh-askpass.ps1" "%REMOTE_SSH_ASKPASS_OUTPUT%" %* >nul',
    'set "REMOTE_SSH_ASKPASS_STATUS=%ERRORLEVEL%"',
    'if "%REMOTE_SSH_ASKPASS_STATUS%"=="0" if exist "%REMOTE_SSH_ASKPASS_OUTPUT%" type "%REMOTE_SSH_ASKPASS_OUTPUT%"',
    'if exist "%REMOTE_SSH_ASKPASS_OUTPUT%" del /f /q "%REMOTE_SSH_ASKPASS_OUTPUT%" >nul 2>nul',
    'exit /b %REMOTE_SSH_ASKPASS_STATUS%',
}

local windows_ps1 = {
    '$outputPath = $args[0]',
    "$promptText = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] -join ' ' } else { 'SSH password:' }",
    'Add-Type -AssemblyName System.Windows.Forms',
    'Add-Type -AssemblyName System.Drawing',
    '$form = New-Object System.Windows.Forms.Form',
    "$form.Text = 'Remote SSH password'",
    "$form.StartPosition = 'CenterScreen'",
    '$form.Width = 420',
    '$form.Height = 150',
    '$form.TopMost = $true',
    '$label = New-Object System.Windows.Forms.Label',
    '$label.Left = 12',
    '$label.Top = 14',
    '$label.Width = 380',
    '$label.Height = 20',
    '$label.Text = $promptText',
    '$textBox = New-Object System.Windows.Forms.TextBox',
    '$textBox.Left = 12',
    '$textBox.Top = 42',
    '$textBox.Width = 380',
    '$textBox.UseSystemPasswordChar = $true',
    '$ok = New-Object System.Windows.Forms.Button',
    "$ok.Text = 'OK'",
    '$ok.Left = 236',
    '$ok.Top = 76',
    '$ok.Width = 75',
    '$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK',
    '$cancel = New-Object System.Windows.Forms.Button',
    "$cancel.Text = 'Cancel'",
    '$cancel.Left = 317',
    '$cancel.Top = 76',
    '$cancel.Width = 75',
    '$cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel',
    '$form.Controls.AddRange(@($label, $textBox, $ok, $cancel))',
    '$form.AcceptButton = $ok',
    '$form.CancelButton = $cancel',
    '$form.Add_Shown({ $textBox.Select() })',
    '$result = $form.ShowDialog()',
    'if ($result -eq [System.Windows.Forms.DialogResult]::OK) {',
    '    $encoding = New-Object System.Text.UTF8Encoding $false',
    '    [System.IO.File]::WriteAllText($outputPath, $textBox.Text + [Environment]::NewLine, $encoding)',
    '    exit 0',
    '}',
    'exit 1',
}

local macos_dialog = 'set dialogResult to display dialog promptText default answer "" with hidden answer'
    .. ' with title "Remote SSH password" buttons {"Cancel", "OK"} default button "OK" cancel button "Cancel"'

local macos_sh = {
    '#!/bin/sh',
    'output=$(mktemp "${TMPDIR:-/tmp}/remote-ssh-askpass.XXXXXX") || exit 1',
    'prompt=$*',
    '[ -n "$prompt" ] || prompt="SSH password:"',
    'trap \'rm -f "$output"\' EXIT HUP INT TERM',
    "REMOTE_SSH_ASKPASS_PROMPT=$prompt REMOTE_SSH_ASKPASS_OUTPUT=$output osascript >/dev/null <<'APPLESCRIPT'",
    'set promptText to system attribute "REMOTE_SSH_ASKPASS_PROMPT"',
    'set outputPath to system attribute "REMOTE_SSH_ASKPASS_OUTPUT"',
    macos_dialog,
    'set outputHandle to open for access (POSIX file outputPath) with write permission',
    'try',
    '    set eof outputHandle to 0',
    '    write ((text returned of dialogResult) & linefeed) to outputHandle',
    '    close access outputHandle',
    'on error errorMessage number errorNumber',
    '    try',
    '        close access outputHandle',
    '    end try',
    '    error errorMessage number errorNumber',
    'end try',
    'APPLESCRIPT',
    'status=$?',
    'if [ "$status" -eq 0 ] && [ -f "$output" ]; then',
    '    cat "$output"',
    'fi',
    'exit "$status"',
}

local unix_sh = {
    '#!/bin/sh',
    'output=$(mktemp "${TMPDIR:-/tmp}/remote-ssh-askpass.XXXXXX") || exit 1',
    'prompt=$*',
    '[ -n "$prompt" ] || prompt="SSH password:"',
    'trap \'rm -f "$output"\' EXIT HUP INT TERM',
    'emit_last_line() {',
    '    sed -n \'$p\' "$output"',
    '}',
    'if command -v python3 >/dev/null 2>&1; then',
    "    REMOTE_SSH_ASKPASS_OUTPUT=$output REMOTE_SSH_ASKPASS_PROMPT=$prompt python3 - <<'PY' >/dev/null 2>/dev/null",
    'import os',
    'import sys',
    'try:',
    '    import tkinter as tk',
    '    from tkinter import simpledialog',
    'except Exception:',
    '    sys.exit(1)',
    'root = tk.Tk()',
    'root.withdraw()',
    'root.attributes("-topmost", True)',
    'password = simpledialog.askstring(',
    '    "Remote SSH password",',
    '    os.environ.get("REMOTE_SSH_ASKPASS_PROMPT", "SSH password:"),',
    '    show="*",',
    ')',
    'root.destroy()',
    'if password is None:',
    '    sys.exit(1)',
    'with open(os.environ["REMOTE_SSH_ASKPASS_OUTPUT"], "w", encoding="utf-8", newline="") as handle:',
    '    handle.write(password + "\\n")',
    'PY',
    '    status=$?',
    '    if [ "$status" -eq 0 ] && [ -f "$output" ]; then',
    '        cat "$output"',
    '        exit 0',
    '    fi',
    'fi',
    'if command -v zenity >/dev/null 2>&1; then',
    '    zenity --password --title="Remote SSH password" > "$output" || exit $?',
    '    emit_last_line',
    '    exit 0',
    'fi',
    'if command -v kdialog >/dev/null 2>&1; then',
    '    kdialog --password "$prompt" > "$output" || exit $?',
    '    emit_last_line',
    '    exit 0',
    'fi',
    'if command -v ssh-askpass >/dev/null 2>&1; then',
    '    ssh-askpass "$prompt" > "$output" || exit $?',
    '    emit_last_line',
    '    exit 0',
    'fi',
    'if command -v ksshaskpass >/dev/null 2>&1; then',
    '    ksshaskpass "$prompt" > "$output" || exit $?',
    '    emit_last_line',
    '    exit 0',
    'fi',
    "printf '%s\\n' 'No graphical askpass helper found' >&2",
    'exit 1',
}

local function executable(path)
    return type(path) == 'string' and path ~= '' and vim.fn.executable(path) == 1
end

local function command_path(command)
    local path = vim.fn.exepath(command)
    return executable(path) and path or nil
end

local function write_if_changed(path, lines)
    local current = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path, 'b') or nil
    if current and vim.deep_equal(current, lines) then
        return true
    end
    return vim.fn.writefile(lines, path, 'b') == 0
end

local function helper_path(name)
    local directory = vim.fs.joinpath(vim.fn.stdpath('cache'), 'remote-ssh', 'askpass')
    vim.fn.mkdir(directory, 'p', tonumber('0700', 8))
    return directory, vim.fs.joinpath(directory, name)
end

local function make_executable(path)
    if vim.fn.has('win32') ~= 1 then
        vim.uv.fs_chmod(path, tonumber('0700', 8))
    end
end

local function windows_askpass()
    local directory, cmd_path = helper_path('remote-ssh-askpass.cmd')
    local ps1_path = vim.fs.joinpath(directory, 'remote-ssh-askpass.ps1')
    if write_if_changed(cmd_path, windows_cmd) and write_if_changed(ps1_path, windows_ps1) and executable(cmd_path) then
        return cmd_path
    end

    return nil, 'Unable to create the Windows askpass helper'
end

local function script_askpass(name, lines)
    local _, path = helper_path(name)
    if write_if_changed(path, lines) then
        make_executable(path)
        if executable(path) then
            return path
        end
    end
    return nil, 'Unable to create the askpass helper'
end

local function unix_askpass()
    for _, command in ipairs({ 'python3', 'zenity', 'kdialog', 'ssh-askpass', 'ksshaskpass' }) do
        if command_path(command) then
            return script_askpass('remote-ssh-askpass', unix_sh)
        end
    end
    return nil, 'Password authentication requires a graphical askpass helper'
end

local function generated_askpass()
    if vim.fn.has('win32') == 1 then
        return windows_askpass()
    end
    if vim.fn.has('macunix') == 1 and command_path('osascript') then
        return script_askpass('remote-ssh-askpass', macos_sh)
    end
    if vim.fn.has('unix') == 1 then
        return unix_askpass()
    end
    return nil, 'Password authentication requires a graphical askpass helper'
end

function M.resolve(configured)
    if configured and configured ~= '' then
        local path = command_path(configured)
        if path then
            return path
        end
        return nil, 'Configured askpass_command is not executable: ' .. configured
    end

    if vim.env.SSH_ASKPASS and vim.env.SSH_ASKPASS ~= '' then
        local path = command_path(vim.env.SSH_ASKPASS)
        if path then
            return path
        end
    end

    local generated_helper, generated_error = generated_askpass()
    if generated_helper then
        return generated_helper
    end

    for _, command in ipairs({ 'ssh-askpass', 'ksshaskpass' }) do
        local path = command_path(command)
        if path then
            return path
        end
    end

    for _, path in ipairs({ '/usr/lib/ssh/ssh-askpass', '/usr/libexec/ssh-askpass' }) do
        if executable(path) then
            return path
        end
    end

    return nil, generated_error or 'Password authentication requires an SSH askpass helper; configure askpass_command'
end

function M.environment(path)
    return {
        SSH_ASKPASS = path,
        SSH_ASKPASS_REQUIRE = 'force',
    }
end

M._windows_askpass = windows_askpass
M._generated_askpass = generated_askpass

return M
