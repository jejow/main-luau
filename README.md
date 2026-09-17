# Main Luau

## Farm Pearl

Current: v23. Route: Lobby / Game Delay -> Bonfire -> Volcano -> 500 Doubloons -> Base / Defense -> buy Pearl -> Lobby.

Use this dedicated loader. It supplies the downloaded source to the farm's built-in teleport continuation, when supported by the executor, without requiring a local `farm pearl.txt` file.

```luau
loadstring(game:HttpGet("https://raw.githubusercontent.com/jejow/main-luau/refs/heads/main/farm_pearl_loader.luau"))()
```

## 100 Days at Sea

Current: v58. Builder advances after observed Outpost changes, tracks pending remove/place responses, and temporarily suspends the native Wrench aiming script during auto-remove. Stop restores its original state.

```luau
loadstring(game:HttpGet("https://raw.githubusercontent.com/jejow/main-luau/refs/heads/main/100days_at_sea.luau"))()
```

## Merge a Nuke

```luau
loadstring(game:HttpGet("https://raw.githubusercontent.com/jejow/main-luau/refs/heads/main/merge%20a%20nuke.luau"))()
```
