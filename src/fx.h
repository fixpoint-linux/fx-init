/* fx.h — shared types + config loader for the fixpoint-linux M4 init system.
 *
 * Owned by THIS repo (fx-init).  config.c implements fx_config_load; the
 * activation tool (fx-activate.c) consumes FxConfig to compute a generation
 * and emit a per-generation dhake buildfile; the supervisor (fx-init.c) does
 * NOT include this header — it reads service facts back out of the store DB
 * (build-time eval; no Dhall interpreter in PID1).
 *
 * Schema (v1, dhall-c-subset-safe):
 *   let Probe   = < Tcp : Natural | Unix : Text | File : Text >
 *   let Service = { name : Text, argv : List Text, pkg : Optional Text,
 *                   on : Text, restart : Optional Text,
 *                   backoffMs : Optional Natural, probe : Optional Probe,
 *                   env : Optional (List { key : Text, value : Text }) }
 *   let User    = { name : Text, uid : Natural, groups : List Text }
 *   in  { hostname : Text, packages : List Text, users : List User,
 *         services : List Service,
 *         extraEtc : Optional (List { path : Text, content : Text }),
 *         bootGraceMs : Optional Natural }
 *
 * `env` is a list of {key,value} records (the simplest Dhall shape that
 * both typechecks and walks cleanly); `extraEtc` likewise uses {path,content}.
 * DESIGN.md §3.3's `command : Text` is superseded by `argv : List Text`
 * (a shell in PID1 would contradict "lean init" + no-/bin/sh chroot).
 */
#ifndef FX_H
#define FX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ─── on= readiness grammar ────────────────────────────────────────────────
 *   on=all            wave 0
 *   on=up:<svc>       start when ready(<svc>) fires
 *   on=sock:tcp:<p>   wait until 127.0.0.1:<p> accepts (retry loop)
 *   on=sock:unix:<a>  wait until AF_UNIX <a> accepts (retry loop)
 *   on=time:<ms>      one-shot timer from boot start
 *   on=net            fires when the probe loop sees any non-lo iface UP
 */
typedef enum {
    FX_ON_ALL,
    FX_ON_UP,
    FX_ON_SOCK_TCP,
    FX_ON_SOCK_UNIX,
    FX_ON_TIME,
    FX_ON_NET
} FxOnKind;

typedef enum {
    FX_PROBE_NONE,
    FX_PROBE_TCP,          /* arg = port (decimal) */
    FX_PROBE_UNIX,         /* arg = absolute path */
    FX_PROBE_FILE          /* arg = absolute path */
} FxProbeKind;

typedef enum {
    FX_RESTART_ALWAYS,     /* default */
    FX_RESTART_ON_FAILURE,
    FX_RESTART_NEVER
} FxRestart;

typedef struct {
    char    *key;
    char    *value;
} FxEnv;

typedef struct {
    char      *name;
    char     **argv;          /* NULL-terminated */
    int        nargv;
    char      *pkg;           /* optional store package name; NULL => argv[0] is absolute */
    FxOnKind   on_kind;
    char      *on_arg;        /* svc name (up:), port string (sock:tcp:), path (sock:unix:), ms (time:) */
    FxRestart  restart;
    uint32_t   backoff_ms;    /* default 1000 */
    FxProbeKind probe_kind;
    char      *probe_arg;     /* port / path */
    FxEnv     *env;
    int        nenv;
} FxService;

typedef struct {
    char  *name;
    uint32_t uid;
    char **groups;            /* NULL-terminated */
    int    ngroups;
} FxUser;

typedef struct {
    char *path;               /* relative under etc/, no .. */
    char *content;
} FxEtcFile;

typedef struct {
    char      *hostname;
    char     **packages;      /* NULL-terminated */
    int        npackages;
    FxUser    *users;
    int        nusers;
    FxService *services;
    int        nservices;
    FxEtcFile *extra_etc;
    int        nextra_etc;
    uint32_t   grace_ms;       /* default 30000 */
} FxConfig;

/* Evaluate config.dhall (parse_source -> infer_type [warning-only] ->
 * normalize -> structural walk) into a malloc'd FxConfig.  Returns 0/-1
 * (err set).  Mirrors fx_packageset_load exactly (packageset.c pipeline). */
int  fx_config_load(FxConfig *out, const char *path, char *err, size_t errcap);

/* Free a config loaded by fx_config_load (NULL-safe). */
void fx_config_free(FxConfig *c);

#ifdef __cplusplus
}
#endif
#endif /* FX_H */
