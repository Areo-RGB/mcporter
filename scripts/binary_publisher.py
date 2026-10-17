#!/usr/bin/env python3
"""Small Tkinter front end for generating and publishing MCP binaries."""

from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from tkinter.scrolledtext import ScrolledText
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
UPLOAD_SCRIPT = ROOT / "scripts" / "upload-binaries.sh"


def safe_name(value: str) -> str:
    """Convert a config name into a portable binary basename."""
    normalized = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-")
    return normalized or "mcp-server"


def normalize_server(name: str, raw: dict[str, Any]) -> dict[str, Any]:
    """Convert common mcporter config entries into an inline server definition."""
    if isinstance(raw.get("command"), dict):
        command = dict(raw["command"])
    elif raw.get("type") == "stdio" or raw.get("executable"):
        executable = raw.get("executable") or raw.get("command")
        if not isinstance(executable, str):
            raise ValueError(f"{name}: stdio server needs an executable or command")
        command = {"kind": "stdio", "command": executable}
        if isinstance(raw.get("args"), list):
            command["args"] = raw["args"]
        if isinstance(raw.get("cwd"), str):
            command["cwd"] = raw["cwd"]
        if isinstance(raw.get("env"), dict):
            command["env"] = raw["env"]
    else:
        url = raw.get("url") or raw.get("baseUrl") or raw.get("serverUrl")
        if not isinstance(url, str) or not url:
            raise ValueError(f"{name}: HTTP server needs url or baseUrl")
        command = {"kind": "http", "url": url}
        if isinstance(raw.get("headers"), dict):
            command["headers"] = raw["headers"]

    definition: dict[str, Any] = {"name": name, "command": command}
    if isinstance(raw.get("description"), str):
        definition["description"] = raw["description"]
    return definition


class PublisherApp:
    def __init__(self, window: tk.Tk) -> None:
        self.window = window
        self.window.title("MCP Binary Publisher")
        self.window.minsize(760, 620)
        self.events: queue.Queue[tuple[str, str]] = queue.Queue()
        self.servers: dict[str, dict[str, Any]] = {}

        self.bucket = tk.StringVar(value=os.environ.get("CF_R2_BUCKET", "cli-porter"))
        self.status = tk.StringVar(value="Paste an MCP config, then load its servers.")
        self.build_ui()
        self.window.after(100, self.process_events)

    def build_ui(self) -> None:
        outer = ttk.Frame(self.window, padding=12)
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(2, weight=1)
        outer.rowconfigure(5, weight=1)

        ttk.Label(outer, text="MCP Binary Publisher", font=("TkDefaultFont", 16, "bold")).grid(
            row=0, column=0, sticky="w"
        )
        ttk.Label(outer, textvariable=self.status).grid(row=1, column=0, sticky="w", pady=(4, 8))

        config_frame = ttk.LabelFrame(outer, text="MCP config JSON")
        config_frame.grid(row=2, column=0, sticky="nsew")
        config_frame.columnconfigure(0, weight=1)
        config_frame.rowconfigure(0, weight=1)
        self.config_text = ScrolledText(config_frame, height=12, wrap="none", undo=True)
        self.config_text.grid(row=0, column=0, sticky="nsew", padx=6, pady=6)

        controls = ttk.Frame(outer)
        controls.grid(row=3, column=0, sticky="ew", pady=8)
        ttk.Label(controls, text="R2 bucket:").pack(side="left")
        ttk.Entry(controls, textvariable=self.bucket, width=24).pack(side="left", padx=(6, 12))
        ttk.Button(controls, text="Load servers", command=self.load_servers).pack(side="left")

        server_frame = ttk.LabelFrame(outer, text="Server")
        server_frame.grid(row=4, column=0, sticky="ew")
        server_frame.columnconfigure(0, weight=1)
        self.server_list = tk.Listbox(server_frame, height=4, exportselection=False)
        self.server_list.grid(row=0, column=0, sticky="ew", padx=6, pady=6)
        self.server_list.bind("<<ListboxSelect>>", self.server_selected)
        self.build_button = ttk.Button(
            server_frame, text="Build Linux + Windows and upload", command=self.start_build, state="disabled"
        )
        self.build_button.grid(row=0, column=1, padx=(0, 6), pady=6)

        log_frame = ttk.LabelFrame(outer, text="Progress")
        log_frame.grid(row=5, column=0, sticky="nsew", pady=(8, 0))
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        self.log_text = ScrolledText(log_frame, height=9, state="disabled", wrap="word")
        self.log_text.grid(row=0, column=0, sticky="nsew", padx=6, pady=6)

    def load_servers(self) -> None:
        try:
            document = json.loads(self.config_text.get("1.0", "end"))
            entries = document.get("mcpServers")
            if not isinstance(entries, dict) or not entries:
                raise ValueError("JSON must contain a non-empty mcpServers object")
            self.servers = {
                name: normalize_server(name, raw)
                for name, raw in entries.items()
                if isinstance(name, str) and isinstance(raw, dict)
            }
            if not self.servers:
                raise ValueError("No valid server entries found")
        except (json.JSONDecodeError, ValueError, TypeError) as error:
            messagebox.showerror("Invalid MCP config", str(error))
            return

        self.server_list.delete(0, "end")
        for name in self.servers:
            self.server_list.insert("end", name)
        self.server_list.selection_set(0)
        self.build_button.configure(state="normal")
        self.status.set(f"Loaded {len(self.servers)} server(s). Select one to build.")

    def server_selected(self, _event: tk.Event[tk.Listbox]) -> None:
        if self.server_list.curselection():
            self.build_button.configure(state="normal")

    def start_build(self) -> None:
        selected = self.server_list.curselection()
        if not selected:
            messagebox.showwarning("No server", "Load the config and select a server first.")
            return
        bucket = self.bucket.get().strip()
        if not bucket:
            messagebox.showwarning("No bucket", "Enter an R2 bucket name first.")
            return

        name = self.server_list.get(selected[0])
        definition = self.servers[name]
        self.build_button.configure(state="disabled")
        self.status.set(f"Building and uploading {name}...")
        threading.Thread(target=self.build_and_upload, args=(name, definition, bucket), daemon=True).start()

    def build_and_upload(self, name: str, definition: dict[str, Any], bucket: str) -> None:
        binary_name = safe_name(name)
        server_json = json.dumps(definition, separators=(",", ":"))
        linux_path = ROOT / binary_name
        windows_path = ROOT / f"{binary_name}.exe"
        bundle_path = ROOT / f"{binary_name}-win.js"

        try:
            self.run_command(
                [
                    "npx",
                    "--yes",
                    "bun",
                    "run",
                    "src/cli.ts",
                    "generate-cli",
                    "--name",
                    binary_name,
                    "--server",
                    server_json,
                    "--runtime",
                    "bun",
                    "--compile",
                    str(linux_path),
                ],
                "Build Linux",
            )
            self.run_command([str(linux_path), "--help"], "Verify Linux")
            self.run_command(
                [
                    "npx",
                    "--yes",
                    "bun",
                    "run",
                    "src/cli.ts",
                    "generate-cli",
                    "--name",
                    binary_name,
                    "--server",
                    server_json,
                    "--runtime",
                    "bun",
                    "--bundle",
                    str(bundle_path),
                ],
                "Build Windows bundle",
            )
            self.run_command(
                [
                    "npx",
                    "--yes",
                    "bun",
                    "build",
                    str(bundle_path),
                    "--compile",
                    "--target",
                    "bun-windows-x64",
                    "--outfile",
                    str(windows_path),
                ],
                "Build Windows",
            )
            bundle_path.unlink(missing_ok=True)
            self.run_command(
                [str(UPLOAD_SCRIPT), str(linux_path), str(windows_path)],
                f"Upload to {bucket}",
                {"CF_R2_BUCKET": bucket},
            )
        except (OSError, subprocess.CalledProcessError) as error:
            self.events.put(("error", str(error)))
            return
        finally:
            bundle_path.unlink(missing_ok=True)

        self.events.put(("done", f"Created and uploaded {binary_name} and {binary_name}.exe."))

    def run_command(self, command: list[str], label: str, extra_env: dict[str, str] | None = None) -> None:
        self.events.put(("log", f"{label}..."))
        environment = os.environ.copy()
        if extra_env:
            environment.update(extra_env)
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        output = (result.stdout + result.stderr).strip()
        if output:
            self.events.put(("log", self.redact(output)))
        if result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, command, output=output)

    @staticmethod
    def redact(output: str) -> str:
        return re.sub(r"(Bearer\s+)[^\s\"']+", r"\1[redacted]", output, flags=re.IGNORECASE)

    def process_events(self) -> None:
        try:
            while True:
                event, message = self.events.get_nowait()
                self.log_text.configure(state="normal")
                self.log_text.insert("end", message + "\n")
                self.log_text.see("end")
                self.log_text.configure(state="disabled")
                if event == "done":
                    self.status.set(message)
                    self.build_button.configure(state="normal")
                    messagebox.showinfo("Complete", message)
                elif event == "error":
                    self.status.set("Build failed.")
                    self.build_button.configure(state="normal")
                    messagebox.showerror("Build failed", message)
        except queue.Empty:
            pass
        self.window.after(100, self.process_events)


def main() -> None:
    root = tk.Tk()
    PublisherApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()