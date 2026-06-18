from ssh_harness_common import *
from ssh_harness_transport_cases import *

def run_proxy_process_recovery_after_daemon_death(tmp, daemon_kind):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    proxy_bin = tmp / "sessh-proxy"
    symlink_role(proxy_bin)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = f"{daemon_kind}-daemon-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = f"{daemon_kind}-daemon-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"
    seed_remote_artifact_cache(env)

    server, server_stop, server_port = start_tcp_echo_server()
    proxy_socket_baseline = remote_proxy_sockets()
    proxy_proc = None
    try:
        proxy_proc = subprocess.Popen(
            [
                str(proxy_bin),
                "--host",
                "test-host",
                "--port",
                str(server_port),
                "--filter-level",
                "unhygienic",
                "--bootstrap",
                "--isolation-mode",
                "process",
            ],
            cwd=ROOT,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        before = f"PROCESS_PROXY_BEFORE_{daemon_kind.upper()}_DAEMON_DEATH\n".encode("utf-8")
        proxy_proc.stdin.write(before)
        proxy_proc.stdin.flush()
        read_until_pipe(proxy_proc.stdout, before, timeout=30.0)

        if daemon_kind == "local":
            daemon_pids = wait_local_daemon_pids(env, timeout=5.0)
        elif daemon_kind == "remote":
            daemon_pids = wait_remote_daemon_pids(env, timeout=5.0)
        else:
            raise AssertionError(f"unknown daemon kind: {daemon_kind}")
        for daemon_pid in daemon_pids:
            os.kill(daemon_pid, signal.SIGKILL)

        after = f"PROCESS_PROXY_AFTER_{daemon_kind.upper()}_DAEMON_DEATH\n".encode("utf-8")
        proxy_proc.stdin.write(after)
        proxy_proc.stdin.flush()
        read_until_pipe(proxy_proc.stdout, after, timeout=45.0)

        if proxy_proc.poll() is not None:
            stderr = proxy_proc.stderr.read().decode("utf-8", "replace")
            raise AssertionError(f"sessh-proxy exited {proxy_proc.returncode}\nstderr:\n{stderr}")

        proxy_proc.stdin.close()
        proxy_proc.stdin = None
        returncode = proxy_proc.wait(timeout=10.0)
        if returncode != 0:
            stderr = proxy_proc.stderr.read().decode("utf-8", "replace")
            raise AssertionError(f"sessh-proxy exited {returncode}\nstderr:\n{stderr}")

        wait_for_no_remote_proxy_sockets(proxy_socket_baseline, timeout=5.0)
    except Exception as exc:
        stderr = ""
        if proxy_proc is not None:
            if proxy_proc.poll() is None:
                terminate_process(proxy_proc)
            stderr = proxy_proc.stderr.read().decode("utf-8", "replace")
        raise AssertionError(
            f"{exc}\n"
            f"proxy stderr:\n{stderr}\n"
            f"fake ssh log:\n{optional_text(fake_log)}\n"
            f"fake ssh trace:\n{optional_text(fake_trace)}"
        ) from exc
    finally:
        if proxy_proc is not None and proxy_proc.poll() is None:
            terminate_process(proxy_proc)
        server_stop.set()
        server.close()

    if ssh_invocation_count(fake_log) < 2:
        raise AssertionError(
            "expected daemon death recovery to establish a replacement ssh transport"
            f"\nlog:\n{optional_text(fake_log)}"
            f"\ntrace:\n{optional_text(fake_trace)}"
        )


def test_ssh_isolation_mode_process_proxy_recovers_after_local_daemon_death(tmp):
    run_proxy_process_recovery_after_daemon_death(tmp, "local")


def test_ssh_isolation_mode_process_proxy_recovers_after_remote_daemon_death(tmp):
    run_proxy_process_recovery_after_daemon_death(tmp, "remote")


def start_proxy_process_for_diagnostics(tmp, diagnostics_args):
    env = isolated_env(tmp)
    fake_bin = tmp / "fake-ssh-bin"
    fake_log = tmp / "fake-ssh.log"
    fake_trace = tmp / "fake-ssh.trace"
    proxy_bin = tmp / "sessh-proxy"
    symlink_role(proxy_bin)
    write_fake_ssh(fake_bin / "ssh")
    env["PATH"] = f"{fake_bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin"
    env["SESSH_FAKE_SSH_LOG"] = str(fake_log)
    env["SESSH_FAKE_SSH_TRACE"] = str(fake_trace)
    env["SESSH_FAKE_SSH_G_USER"] = "proxy-diagnostics-user"
    env["SESSH_FAKE_SSH_G_HOSTNAME"] = "proxy-diagnostics-host"
    env["SESSH_FAKE_SSH_G_PORT"] = "2222"
    seed_remote_artifact_cache(env)

    server, server_stop, server_port = start_tcp_echo_server()
    proxy_proc = subprocess.Popen(
        [
            str(proxy_bin),
            "--host",
            "test-host",
            "--port",
            str(server_port),
            "--filter-level",
            "unhygienic",
            "--bootstrap",
            "--isolation-mode",
            "process",
            *diagnostics_args,
        ],
        cwd=ROOT,
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    marker = b"PROXY_DIAGNOSTICS_READY\n"
    try:
        proxy_proc.stdin.write(marker)
        proxy_proc.stdin.flush()
        try:
            read_until_pipe(proxy_proc.stdout, marker, timeout=30.0)
        except Exception as exc:
            stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
            raise AssertionError(
                f"{exc}\nstdout:\n{stdout}\nstderr:\n{stderr}\n"
                f"fake ssh log:\n{optional_text(fake_log)}\n"
                f"fake ssh trace:\n{optional_text(fake_trace)}"
            ) from exc
        for daemon_pid in wait_remote_daemon_pids(env, timeout=5.0):
            os.kill(daemon_pid, signal.SIGKILL)
        return env, fake_log, fake_trace, server, server_stop, proxy_proc
    except Exception:
        terminate_process(proxy_proc)
        server_stop.set()
        server.close()
        raise


def finish_proxy_diagnostics_process(server, server_stop, proxy_proc):
    if proxy_proc.poll() is None:
        terminate_process(proxy_proc)
    server_stop.set()
    server.close()
    stderr = proxy_proc.stderr.read().decode("utf-8", "replace")
    stdout = proxy_proc.stdout.read().decode("utf-8", "replace")
    return stdout, stderr


def test_ssh_proxy_process_diagnostics_fall_back_to_stderr_lines(tmp):
    env, fake_log, fake_trace, server, server_stop, proxy_proc = start_proxy_process_for_diagnostics(tmp, [])
    try:
        observed_stderr = read_until_pipe(proxy_proc.stderr, b"sessh: disconnected: Retry connecting ", timeout=10.0)
    except Exception as exc:
        stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
        raise AssertionError(
            f"{exc}\nstdout:\n{stdout}\nstderr:\n{stderr}\n"
            f"fake ssh log:\n{optional_text(fake_log)}\n"
            f"fake ssh trace:\n{optional_text(fake_trace)}"
        ) from exc
    else:
        stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
        if b"\r\n" not in observed_stderr:
            raise AssertionError(
                "stderr diagnostics should use CRLF to avoid staircasing\n"
                f"stdout:\n{stdout}\nstderr:\n{observed_stderr.decode('utf-8', 'replace')}{stderr}"
            )


def test_ssh_proxy_process_diagnostics_file_gets_sparse_lines(tmp):
    diagnostics_path = tmp / "proxy-diagnostics.log"
    env, fake_log, fake_trace, server, server_stop, proxy_proc = start_proxy_process_for_diagnostics(
        tmp,
        ["--diagnostics-file", str(diagnostics_path)],
    )
    try:
        diagnostics = wait_for_file_count(
            diagnostics_path,
            "sessh: disconnected: Retry connecting ",
            1,
            timeout=10.0,
        )
    except Exception as exc:
        stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
        raise AssertionError(
            f"{exc}\nstdout:\n{stdout}\nstderr:\n{stderr}\n"
            f"fake ssh log:\n{optional_text(fake_log)}\n"
            f"fake ssh trace:\n{optional_text(fake_trace)}"
        ) from exc
    else:
        stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
        if "sessh: disconnected:" in stderr:
            raise AssertionError(f"explicit diagnostics file leaked to stderr\nstdout:\n{stdout}\nstderr:\n{stderr}")
        if diagnostics.count("sessh: disconnected: Retry connecting") != 1:
            raise AssertionError(diagnostics)


def test_ssh_proxy_process_diagnostics_file_gets_jsonl_when_forced(tmp):
    diagnostics_path = tmp / "proxy-diagnostics.jsonl"
    env, fake_log, fake_trace, server, server_stop, proxy_proc = start_proxy_process_for_diagnostics(
        tmp,
        ["--diagnostics-level", "jsonl", "--diagnostics-file", str(diagnostics_path)],
    )
    try:
        diagnostics = wait_for_file_count(
            diagnostics_path,
            '"event":"retry_scheduled"',
            1,
            timeout=10.0,
        )
    except Exception as exc:
        stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
        raise AssertionError(
            f"{exc}\nstdout:\n{stdout}\nstderr:\n{stderr}\n"
            f"fake ssh log:\n{optional_text(fake_log)}\n"
            f"fake ssh trace:\n{optional_text(fake_trace)}"
        ) from exc
    else:
        stdout, stderr = finish_proxy_diagnostics_process(server, server_stop, proxy_proc)
        if "sessh: disconnected:" in diagnostics or "sessh: disconnected:" in stderr:
            raise AssertionError(f"jsonl diagnostics included human line\nfile:\n{diagnostics}\nstderr:\n{stderr}")
        for line in diagnostics.splitlines():
            json.loads(line)
        if '"retry_at_unix_ms":' not in diagnostics:
            raise AssertionError(diagnostics)


