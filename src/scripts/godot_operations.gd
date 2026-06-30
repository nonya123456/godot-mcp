#!/usr/bin/env -S godot --headless --script
extends SceneTree

# Debug mode flag
var debug_mode = false

func _init():
    var args = OS.get_cmdline_args()
    
    # Check for debug flag
    debug_mode = "--debug-godot" in args
    
    # Find the script argument and determine the positions of operation and params
    var script_index = args.find("--script")
    if script_index == -1:
        log_error("Could not find --script argument")
        quit(1)
    
    # The operation should be 2 positions after the script path (script_index + 1 is the script path itself)
    var operation_index = script_index + 2
    # The params should be 3 positions after the script path
    var params_index = script_index + 3
    
    if args.size() <= params_index:
        log_error("Usage: godot --headless --script godot_operations.gd <operation> <json_params>")
        log_error("Not enough command-line arguments provided.")
        quit(1)
    
    # Log all arguments for debugging
    log_debug("All arguments: " + str(args))
    log_debug("Script index: " + str(script_index))
    log_debug("Operation index: " + str(operation_index))
    log_debug("Params index: " + str(params_index))
    
    var operation = args[operation_index]
    var params_json = args[params_index]
    
    log_info("Operation: " + operation)
    log_debug("Params JSON: " + params_json)
    
    # Parse JSON using Godot 4.x API
    var json = JSON.new()
    var error = json.parse(params_json)
    var params = null
    
    if error == OK:
        params = json.get_data()
    else:
        log_error("Failed to parse JSON parameters: " + params_json)
        log_error("JSON Error: " + json.get_error_message() + " at line " + str(json.get_error_line()))
        quit(1)
    
    if not params:
        log_error("Failed to parse JSON parameters: " + params_json)
        quit(1)
    
    log_info("Executing operation: " + operation)
    
    match operation:
        "create_scene":
            create_scene(params)
        "add_node":
            add_node(params)
        "load_sprite":
            load_sprite(params)
        "export_mesh_library":
            export_mesh_library(params)
        "save_scene":
            save_scene(params)
        "get_scene_tree":
            get_scene_tree(params)
        "update_node_property":
            update_node_property(params)
        "delete_node":
            delete_node(params)
        "rename_node":
            rename_node(params)
        "reparent_node":
            reparent_node(params)
        "add_scene_instance":
            add_scene_instance(params)
        "create_script":
            create_script(params)
        "attach_script":
            attach_script(params)
        "connect_signal":
            connect_signal(params)
        "add_to_group":
            add_to_group(params)
        "get_uid":
            get_uid(params)
        "resave_resources":
            resave_resources(params)
        _:
            log_error("Unknown operation: " + operation)
            quit(1)
    
    quit()

# Logging functions
func log_debug(message):
    if debug_mode:
        print("[DEBUG] " + message)

func log_info(message):
    print("[INFO] " + message)

func log_error(message):
    printerr("[ERROR] " + message)

# --- Shared helpers -------------------------------------------------------

# Normalize a resource path so it begins with res://
func to_res_path(p):
    if p == null:
        return p
    if not p.begins_with("res://"):
        return "res://" + p
    return p

# Load a scene file and return a fresh instance of its tree, or null on error.
func load_scene_instance(scene_path):
    scene_path = to_res_path(scene_path)
    if not FileAccess.file_exists(scene_path):
        printerr("Scene file does not exist at: " + scene_path)
        return null
    var scene = load(scene_path)
    if not scene:
        printerr("Failed to load scene: " + scene_path)
        return null
    return scene.instantiate()

# Pack an instantiated scene tree and write it to disk, creating the target
# directory if needed. Returns OK on success or an error code.
func pack_and_save(scene_root, save_path):
    save_path = to_res_path(save_path)
    var dir_path = save_path.get_base_dir()
    if dir_path != "res://" and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
        var mkerr = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
        if mkerr != OK:
            printerr("Failed to create directory: " + dir_path + " (error " + str(mkerr) + ")")
            return mkerr
    var packed_scene = PackedScene.new()
    var pack_result = packed_scene.pack(scene_root)
    if pack_result != OK:
        printerr("Failed to pack scene: " + str(pack_result))
        return pack_result
    var save_error = ResourceSaver.save(packed_scene, save_path)
    if save_error != OK:
        printerr("Failed to save scene: " + str(save_error))
    return save_error

# Resolve a node inside an instantiated scene from an agent-supplied path.
# Accepts the magic alias "root", the scene root's actual name, an absolute
# style "root/Child/Grandchild" path, or a path relative to the root. Returns
# null if the node cannot be found.
func resolve_node(scene_root, node_path):
    if node_path == null:
        return scene_root
    var p = str(node_path).strip_edges()
    if p == "" or p == "." or p == "root":
        return scene_root
    # Strip an explicit "root/" prefix (the documented convention).
    if p.begins_with("root/"):
        p = p.substr("root/".length())
    elif p == scene_root.name:
        return scene_root
    elif p.begins_with(str(scene_root.name) + "/"):
        p = p.substr(str(scene_root.name).length() + 1)
    if p == "":
        return scene_root
    return scene_root.get_node_or_null(p)

# Convert an agent-supplied JSON value into the concrete type expected by a
# node property. JSON can only carry primitives/arrays/objects, so struct
# types such as Vector2/Color have to be reconstructed before assignment.
# Without this, set("position", [100, 200]) would silently fail.
func coerce_value(node, property, value):
    # res:// strings are loaded as resources (textures, scenes, etc.).
    if typeof(value) == TYPE_STRING and value.begins_with("res://"):
        return load(value)

    # Find the property's declared type from the node's property list.
    var expected_type = TYPE_NIL
    for prop in node.get_property_list():
        if prop.name == property:
            expected_type = prop.type
            break

    return coerce_to_type(value, expected_type)

# Build a typed value from a JSON-friendly value given a Godot TYPE_* code.
# Arrays are interpreted positionally; dictionaries by component name.
func coerce_to_type(value, expected_type):
    var t = typeof(value)

    # Already the right primitive, or no type info: pass through.
    if expected_type == TYPE_NIL:
        return value

    var arr = null
    if t == TYPE_ARRAY:
        arr = value
    elif t == TYPE_DICTIONARY:
        arr = _dict_to_components(value)

    match expected_type:
        TYPE_VECTOR2:
            if arr != null and arr.size() >= 2: return Vector2(arr[0], arr[1])
        TYPE_VECTOR2I:
            if arr != null and arr.size() >= 2: return Vector2i(int(arr[0]), int(arr[1]))
        TYPE_VECTOR3:
            if arr != null and arr.size() >= 3: return Vector3(arr[0], arr[1], arr[2])
        TYPE_VECTOR3I:
            if arr != null and arr.size() >= 3: return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
        TYPE_VECTOR4:
            if arr != null and arr.size() >= 4: return Vector4(arr[0], arr[1], arr[2], arr[3])
        TYPE_COLOR:
            if t == TYPE_STRING: return Color(value)
            if arr != null and arr.size() >= 3:
                var a = arr[3] if arr.size() >= 4 else 1.0
                return Color(arr[0], arr[1], arr[2], a)
        TYPE_RECT2:
            if arr != null and arr.size() >= 4: return Rect2(arr[0], arr[1], arr[2], arr[3])
        _:
            # ints, floats, bools, strings, arrays, dictionaries: assign as-is.
            return value
    # Coercion expected an array/dict but didn't get a usable one.
    return value

func _dict_to_components(d):
    # Map common component names to an ordered array.
    for keys in [["x", "y", "z", "w"], ["r", "g", "b", "a"]]:
        if d.has(keys[0]):
            var out = []
            for k in keys:
                if d.has(k): out.append(d[k])
            return out
    return null

# Get a script by registered class name.
# Only looks up names via the project's global class registry. Raw paths
# (e.g. "res://evil.gd") are intentionally not accepted here to prevent
# arbitrary script instantiation from agent-supplied input.
func get_script_by_name(name_of_class):
    if debug_mode:
        print("Attempting to get script for class: " + name_of_class)

    # Search for it in the global class registry if it's a class name
    var global_classes = ProjectSettings.get_global_class_list()
    if debug_mode:
        print("Searching through " + str(global_classes.size()) + " global classes")
    
    for global_class in global_classes:
        var found_name_of_class = global_class["class"]
        var found_path = global_class["path"]
        
        if found_name_of_class == name_of_class:
            if debug_mode:
                print("Found matching class in registry: " + found_name_of_class + " at path: " + found_path)
            var script = load(found_path) as Script
            if script:
                if debug_mode:
                    print("Successfully loaded script from registry")
                return script
            else:
                printerr("Failed to load script from registry path: " + found_path)
                break
    
    printerr("Could not find script for class: " + name_of_class)
    return null

# Instantiate a class by name
func instantiate_class(name_of_class):
    if name_of_class.is_empty():
        printerr("Cannot instantiate class: name is empty")
        return null
    
    var result = null
    if debug_mode:
        print("Attempting to instantiate class: " + name_of_class)
    
    # Check if it's a built-in class
    if ClassDB.class_exists(name_of_class):
        if debug_mode:
            print("Class exists in ClassDB, using ClassDB.instantiate()")
        if ClassDB.can_instantiate(name_of_class):
            result = ClassDB.instantiate(name_of_class)
            if result == null:
                printerr("ClassDB.instantiate() returned null for class: " + name_of_class)
        else:
            printerr("Class exists but cannot be instantiated: " + name_of_class)
            printerr("This may be an abstract class or interface that cannot be directly instantiated")
    else:
        # Try to get the script
        if debug_mode:
            print("Class not found in ClassDB, trying to get script")
        var script = get_script_by_name(name_of_class)
        if script is GDScript:
            if debug_mode:
                print("Found GDScript, creating instance")
            result = script.new()
        else:
            printerr("Failed to get script for class: " + name_of_class)
            return null
    
    if result == null:
        printerr("Failed to instantiate class: " + name_of_class)
    elif debug_mode:
        print("Successfully instantiated class: " + name_of_class + " of type: " + result.get_class())
    
    return result

# Create a new scene with a specified root node type
func create_scene(params):
    print("Creating scene: " + params.scene_path)
    
    # Get project paths and log them for debugging
    var project_res_path = "res://"
    var project_user_path = "user://"
    var global_res_path = ProjectSettings.globalize_path(project_res_path)
    var global_user_path = ProjectSettings.globalize_path(project_user_path)
    
    if debug_mode:
        print("Project paths:")
        print("- res:// path: " + project_res_path)
        print("- user:// path: " + project_user_path)
        print("- Globalized res:// path: " + global_res_path)
        print("- Globalized user:// path: " + global_user_path)
        
        # Print some common environment variables for debugging
        print("Environment variables:")
        var env_vars = ["PATH", "HOME", "USER", "TEMP", "GODOT_PATH"]
        for env_var in env_vars:
            if OS.has_environment(env_var):
                print("  " + env_var + " = " + OS.get_environment(env_var))
    
    # Normalize the scene path
    var full_scene_path = params.scene_path
    if not full_scene_path.begins_with("res://"):
        full_scene_path = "res://" + full_scene_path
    if debug_mode:
        print("Scene path (with res://): " + full_scene_path)
    
    # Convert resource path to an absolute path
    var absolute_scene_path = ProjectSettings.globalize_path(full_scene_path)
    if debug_mode:
        print("Absolute scene path: " + absolute_scene_path)
    
    # Get the scene directory paths
    var scene_dir_res = full_scene_path.get_base_dir()
    var scene_dir_abs = absolute_scene_path.get_base_dir()
    if debug_mode:
        print("Scene directory (resource path): " + scene_dir_res)
        print("Scene directory (absolute path): " + scene_dir_abs)
    
    # Only do extensive testing in debug mode
    if debug_mode:
        # Try to create a simple test file in the project root to verify write access
        var initial_test_file_path = "res://godot_mcp_test_write.tmp"
        var initial_test_file = FileAccess.open(initial_test_file_path, FileAccess.WRITE)
        if initial_test_file:
            initial_test_file.store_string("Test write access")
            initial_test_file.close()
            print("Successfully wrote test file to project root: " + initial_test_file_path)
            
            # Verify the test file exists
            var initial_test_file_exists = FileAccess.file_exists(initial_test_file_path)
            print("Test file exists check: " + str(initial_test_file_exists))
            
            # Clean up the test file
            if initial_test_file_exists:
                var remove_error = DirAccess.remove_absolute(ProjectSettings.globalize_path(initial_test_file_path))
                print("Test file removal result: " + str(remove_error))
        else:
            var write_error = FileAccess.get_open_error()
            printerr("Failed to write test file to project root: " + str(write_error))
            printerr("This indicates a serious permission issue with the project directory")
    
    # Use traditional if-else statement for better compatibility
    var root_node_type = "Node2D"  # Default value
    if params.has("root_node_type"):
        root_node_type = params.root_node_type
    if debug_mode:
        print("Root node type: " + root_node_type)
    
    # Create the root node
    var scene_root = instantiate_class(root_node_type)
    if not scene_root:
        printerr("Failed to instantiate node of type: " + root_node_type)
        printerr("Make sure the class exists and can be instantiated")
        printerr("Check if the class is registered in ClassDB or available as a script")
        quit(1)
    
    # Match the editor: a new scene's root node is named after its type
    # (e.g. "Node2D"), not the literal string "root". Node operations still
    # accept "root" as an alias for the scene root via resolve_node().
    scene_root.name = root_node_type
    if debug_mode:
        print("Root node created with name: " + scene_root.name)

    # The scene root's owner must stay null. Setting it to itself triggers a
    # Godot error ("Condition p_owner == this is true") and is not how the
    # editor saves scenes.
    
    # Pack the scene
    var packed_scene = PackedScene.new()
    var result = packed_scene.pack(scene_root)
    if debug_mode:
        print("Pack result: " + str(result) + " (OK=" + str(OK) + ")")
    
    if result == OK:
        # Only do extensive testing in debug mode
        if debug_mode:
            # First, let's verify we can write to the project directory
            print("Testing write access to project directory...")
            var test_write_path = "res://test_write_access.tmp"
            var test_write_abs = ProjectSettings.globalize_path(test_write_path)
            var test_file = FileAccess.open(test_write_path, FileAccess.WRITE)
            
            if test_file:
                test_file.store_string("Write test")
                test_file.close()
                print("Successfully wrote test file to project directory")
                
                # Clean up test file
                if FileAccess.file_exists(test_write_path):
                    var remove_error = DirAccess.remove_absolute(test_write_abs)
                    print("Test file removal result: " + str(remove_error))
            else:
                var write_error = FileAccess.get_open_error()
                printerr("Failed to write test file to project directory: " + str(write_error))
                printerr("This may indicate permission issues with the project directory")
                # Continue anyway, as the scene directory might still be writable
        
        # Ensure the scene directory exists using DirAccess
        if debug_mode:
            print("Ensuring scene directory exists...")
        
        # Get the scene directory relative to res://
        var scene_dir_relative = scene_dir_res.substr(6)  # Remove "res://" prefix
        if debug_mode:
            print("Scene directory (relative to res://): " + scene_dir_relative)
        
        # Create the directory if needed
        if not scene_dir_relative.is_empty():
            # First check if it exists
            var dir_exists = DirAccess.dir_exists_absolute(scene_dir_abs)
            if debug_mode:
                print("Directory exists check (absolute): " + str(dir_exists))
            
            if not dir_exists:
                if debug_mode:
                    print("Directory doesn't exist, creating: " + scene_dir_relative)
                
                # Try to create the directory using DirAccess
                var dir = DirAccess.open("res://")
                if dir == null:
                    var open_error = DirAccess.get_open_error()
                    printerr("Failed to open res:// directory: " + str(open_error))
                    
                    # Try alternative approach with absolute path
                    if debug_mode:
                        print("Trying alternative directory creation approach...")
                    var make_dir_error = DirAccess.make_dir_recursive_absolute(scene_dir_abs)
                    if debug_mode:
                        print("Make directory result (absolute): " + str(make_dir_error))
                    
                    if make_dir_error != OK:
                        printerr("Failed to create directory using absolute path")
                        printerr("Error code: " + str(make_dir_error))
                        quit(1)
                else:
                    # Create the directory using the DirAccess instance
                    if debug_mode:
                        print("Creating directory using DirAccess: " + scene_dir_relative)
                    var make_dir_error = dir.make_dir_recursive(scene_dir_relative)
                    if debug_mode:
                        print("Make directory result: " + str(make_dir_error))
                    
                    if make_dir_error != OK:
                        printerr("Failed to create directory: " + scene_dir_relative)
                        printerr("Error code: " + str(make_dir_error))
                        quit(1)
                
                # Verify the directory was created
                dir_exists = DirAccess.dir_exists_absolute(scene_dir_abs)
                if debug_mode:
                    print("Directory exists check after creation: " + str(dir_exists))
                
                if not dir_exists:
                    printerr("Directory reported as created but does not exist: " + scene_dir_abs)
                    printerr("This may indicate a problem with path resolution or permissions")
                    quit(1)
            elif debug_mode:
                print("Directory already exists: " + scene_dir_abs)
        
        # Save the scene
        if debug_mode:
            print("Saving scene to: " + full_scene_path)
        var save_error = ResourceSaver.save(packed_scene, full_scene_path)
        if debug_mode:
            print("Save result: " + str(save_error) + " (OK=" + str(OK) + ")")
        
        if save_error == OK:
            # Only do extensive testing in debug mode
            if debug_mode:
                # Wait a moment to ensure file system has time to complete the write
                print("Waiting for file system to complete write operation...")
                OS.delay_msec(500)  # 500ms delay
                
                # Verify the file was actually created using multiple methods
                var file_check_abs = FileAccess.file_exists(absolute_scene_path)
                print("File exists check (absolute path): " + str(file_check_abs))
                
                var file_check_res = FileAccess.file_exists(full_scene_path)
                print("File exists check (resource path): " + str(file_check_res))
                
                var res_exists = ResourceLoader.exists(full_scene_path)
                print("Resource exists check: " + str(res_exists))
                
                # If file doesn't exist by absolute path, try to create a test file in the same directory
                if not file_check_abs and not file_check_res:
                    printerr("Scene file not found after save. Trying to diagnose the issue...")
                    
                    # Try to write a test file to the same directory
                    var test_scene_file_path = scene_dir_res + "/test_scene_file.tmp"
                    var test_scene_file = FileAccess.open(test_scene_file_path, FileAccess.WRITE)
                    
                    if test_scene_file:
                        test_scene_file.store_string("Test scene directory write")
                        test_scene_file.close()
                        print("Successfully wrote test file to scene directory: " + test_scene_file_path)
                        
                        # Check if the test file exists
                        var test_file_exists = FileAccess.file_exists(test_scene_file_path)
                        print("Test file exists: " + str(test_file_exists))
                        
                        if test_file_exists:
                            # Directory is writable, so the issue is with scene saving
                            printerr("Directory is writable but scene file wasn't created.")
                            printerr("This suggests an issue with ResourceSaver.save() or the packed scene.")
                            
                            # Try saving with a different approach
                            print("Trying alternative save approach...")
                            var alt_save_error = ResourceSaver.save(packed_scene, test_scene_file_path + ".tscn")
                            print("Alternative save result: " + str(alt_save_error))
                            
                            # Clean up test files
                            DirAccess.remove_absolute(ProjectSettings.globalize_path(test_scene_file_path))
                            if alt_save_error == OK:
                                DirAccess.remove_absolute(ProjectSettings.globalize_path(test_scene_file_path + ".tscn"))
                        else:
                            printerr("Test file couldn't be verified. This suggests filesystem access issues.")
                    else:
                        var write_error = FileAccess.get_open_error()
                        printerr("Failed to write test file to scene directory: " + str(write_error))
                        printerr("This confirms there are permission or path issues with the scene directory.")
                    
                    # Return error since we couldn't create the scene file
                    printerr("Failed to create scene: " + params.scene_path)
                    quit(1)
                
                # If we get here, at least one of our file checks passed
                if file_check_abs or file_check_res or res_exists:
                    print("Scene file verified to exist!")
                    
                    # Try to load the scene to verify it's valid
                    var test_load = ResourceLoader.load(full_scene_path)
                    if test_load:
                        print("Scene created and verified successfully at: " + params.scene_path)
                        print("Scene file can be loaded correctly.")
                    else:
                        print("Scene file exists but cannot be loaded. It may be corrupted or incomplete.")
                        # Continue anyway since the file exists
                    
                    print("Scene created successfully at: " + params.scene_path)
                else:
                    printerr("All file existence checks failed despite successful save operation.")
                    printerr("This indicates a serious issue with file system access or path resolution.")
                    quit(1)
            else:
                # In non-debug mode, just check if the file exists
                var file_exists = FileAccess.file_exists(full_scene_path)
                if file_exists:
                    print("Scene created successfully at: " + params.scene_path)
                else:
                    printerr("Failed to create scene: " + params.scene_path)
                    quit(1)
        else:
            # Handle specific error codes
            var error_message = "Failed to save scene. Error code: " + str(save_error)
            
            if save_error == ERR_CANT_CREATE:
                error_message += " (ERR_CANT_CREATE - Cannot create the scene file)"
            elif save_error == ERR_CANT_OPEN:
                error_message += " (ERR_CANT_OPEN - Cannot open the scene file for writing)"
            elif save_error == ERR_FILE_CANT_WRITE:
                error_message += " (ERR_FILE_CANT_WRITE - Cannot write to the scene file)"
            elif save_error == ERR_FILE_NO_PERMISSION:
                error_message += " (ERR_FILE_NO_PERMISSION - No permission to write the scene file)"
            
            printerr(error_message)
            quit(1)
    else:
        printerr("Failed to pack scene: " + str(result))
        printerr("Error code: " + str(result))
        quit(1)

# Add a node to an existing scene
func add_node(params):
    print("Adding node to scene: " + params.scene_path)
    
    var full_scene_path = params.scene_path
    if not full_scene_path.begins_with("res://"):
        full_scene_path = "res://" + full_scene_path
    if debug_mode:
        print("Scene path (with res://): " + full_scene_path)
    
    var absolute_scene_path = ProjectSettings.globalize_path(full_scene_path)
    if debug_mode:
        print("Absolute scene path: " + absolute_scene_path)
    
    if not FileAccess.file_exists(absolute_scene_path):
        printerr("Scene file does not exist at: " + absolute_scene_path)
        quit(1)
    
    var scene = load(full_scene_path)
    if not scene:
        printerr("Failed to load scene: " + full_scene_path)
        quit(1)
    
    if debug_mode:
        print("Scene loaded successfully")
    var scene_root = scene.instantiate()
    if debug_mode:
        print("Scene instantiated")
    
    # Resolve the parent node ("root" alias, root name, or relative path).
    var parent_path = params.parent_node_path if params.has("parent_node_path") else "root"
    if debug_mode:
        print("Parent path: " + str(parent_path))

    var parent = resolve_node(scene_root, parent_path)
    if not parent:
        printerr("Parent node not found: " + str(parent_path))
        quit(1)
    if debug_mode:
        print("Parent node found: " + str(parent.name))
    
    if debug_mode:
        print("Instantiating node of type: " + params.node_type)
    var new_node = instantiate_class(params.node_type)
    if not new_node:
        printerr("Failed to instantiate node of type: " + params.node_type)
        printerr("Make sure the class exists and can be instantiated")
        printerr("Check if the class is registered in ClassDB or available as a script")
        quit(1)
    new_node.name = params.node_name
    if debug_mode:
        print("New node created with name: " + new_node.name)
    
    if params.has("properties"):
        if debug_mode:
            print("Setting properties on node")
        var properties = params.properties
        for property in properties:
            if debug_mode:
                print("Setting property: " + property + " = " + str(properties[property]))
            var value = coerce_value(new_node, property, properties[property])
            if debug_mode:
                print("Coerced value for property: " + property + " -> " + str(value))
            new_node.set(property, value)
    
    parent.add_child(new_node)
    new_node.owner = scene_root
    if debug_mode:
        print("Node added to parent and ownership set")
    
    var packed_scene = PackedScene.new()
    var result = packed_scene.pack(scene_root)
    if debug_mode:
        print("Pack result: " + str(result) + " (OK=" + str(OK) + ")")
    
    if result == OK:
        if debug_mode:
            print("Saving scene to: " + absolute_scene_path)
        var save_error = ResourceSaver.save(packed_scene, absolute_scene_path)
        if debug_mode:
            print("Save result: " + str(save_error) + " (OK=" + str(OK) + ")")
        if save_error == OK:
            if debug_mode:
                var file_check_after = FileAccess.file_exists(absolute_scene_path)
                print("File exists check after save: " + str(file_check_after))
                if file_check_after:
                    print("Node '" + params.node_name + "' of type '" + params.node_type + "' added successfully")
                else:
                    printerr("File reported as saved but does not exist at: " + absolute_scene_path)
            else:
                print("Node '" + params.node_name + "' of type '" + params.node_type + "' added successfully")
        else:
            printerr("Failed to save scene: " + str(save_error))
    else:
        printerr("Failed to pack scene: " + str(result))

# Load a sprite into a Sprite2D node
func load_sprite(params):
    print("Loading sprite into scene: " + params.scene_path)
    
    # Ensure the scene path starts with res:// for Godot's resource system
    var full_scene_path = params.scene_path
    if not full_scene_path.begins_with("res://"):
        full_scene_path = "res://" + full_scene_path
    
    if debug_mode:
        print("Full scene path (with res://): " + full_scene_path)
    
    # Check if the scene file exists
    var file_check = FileAccess.file_exists(full_scene_path)
    if debug_mode:
        print("Scene file exists check: " + str(file_check))
    
    if not file_check:
        printerr("Scene file does not exist at: " + full_scene_path)
        # Get the absolute path for reference
        var absolute_path = ProjectSettings.globalize_path(full_scene_path)
        printerr("Absolute file path that doesn't exist: " + absolute_path)
        quit(1)
    
    # Ensure the texture path starts with res:// for Godot's resource system
    var full_texture_path = params.texture_path
    if not full_texture_path.begins_with("res://"):
        full_texture_path = "res://" + full_texture_path
    
    if debug_mode:
        print("Full texture path (with res://): " + full_texture_path)
    
    # Load the scene
    var scene = load(full_scene_path)
    if not scene:
        printerr("Failed to load scene: " + full_scene_path)
        quit(1)
    
    if debug_mode:
        print("Scene loaded successfully")
    
    # Instance the scene
    var scene_root = scene.instantiate()
    if debug_mode:
        print("Scene instantiated")
    
    # Find the sprite node
    var node_path = params.node_path
    if debug_mode:
        print("Original node path: " + node_path)
    
    if node_path.begins_with("root/"):
        node_path = node_path.substr(5)  # Remove "root/" prefix
        if debug_mode:
            print("Node path after removing 'root/' prefix: " + node_path)
    
    var sprite_node = null
    if node_path == "":
        # If no node path, assume root is the sprite
        sprite_node = scene_root
        if debug_mode:
            print("Using root node as sprite node")
    else:
        sprite_node = scene_root.get_node(node_path)
        if sprite_node and debug_mode:
            print("Found sprite node: " + sprite_node.name)
    
    if not sprite_node:
        printerr("Node not found: " + params.node_path)
        quit(1)
    
    # Check if the node is a Sprite2D or compatible type
    if debug_mode:
        print("Node class: " + sprite_node.get_class())
    if not (sprite_node is Sprite2D or sprite_node is Sprite3D or sprite_node is TextureRect):
        printerr("Node is not a sprite-compatible type: " + sprite_node.get_class())
        quit(1)
    
    # Load the texture
    if debug_mode:
        print("Loading texture from: " + full_texture_path)
    var texture = load(full_texture_path)
    if not texture:
        printerr("Failed to load texture: " + full_texture_path)
        quit(1)
    
    if debug_mode:
        print("Texture loaded successfully")
    
    # Set the texture on the sprite
    if sprite_node is Sprite2D or sprite_node is Sprite3D:
        sprite_node.texture = texture
        if debug_mode:
            print("Set texture on Sprite2D/Sprite3D node")
    elif sprite_node is TextureRect:
        sprite_node.texture = texture
        if debug_mode:
            print("Set texture on TextureRect node")
    
    # Save the modified scene
    var packed_scene = PackedScene.new()
    var result = packed_scene.pack(scene_root)
    if debug_mode:
        print("Pack result: " + str(result) + " (OK=" + str(OK) + ")")
    
    if result == OK:
        if debug_mode:
            print("Saving scene to: " + full_scene_path)
        var error = ResourceSaver.save(packed_scene, full_scene_path)
        if debug_mode:
            print("Save result: " + str(error) + " (OK=" + str(OK) + ")")
        
        if error == OK:
            # Verify the file was actually updated
            if debug_mode:
                var file_check_after = FileAccess.file_exists(full_scene_path)
                print("File exists check after save: " + str(file_check_after))
                
                if file_check_after:
                    print("Sprite loaded successfully with texture: " + full_texture_path)
                    # Get the absolute path for reference
                    var absolute_path = ProjectSettings.globalize_path(full_scene_path)
                    print("Absolute file path: " + absolute_path)
                else:
                    printerr("File reported as saved but does not exist at: " + full_scene_path)
            else:
                print("Sprite loaded successfully with texture: " + full_texture_path)
        else:
            printerr("Failed to save scene: " + str(error))
    else:
        printerr("Failed to pack scene: " + str(result))

# Export a scene as a MeshLibrary resource
func export_mesh_library(params):
    print("Exporting MeshLibrary from scene: " + params.scene_path)
    
    # Ensure the scene path starts with res:// for Godot's resource system
    var full_scene_path = params.scene_path
    if not full_scene_path.begins_with("res://"):
        full_scene_path = "res://" + full_scene_path
    
    if debug_mode:
        print("Full scene path (with res://): " + full_scene_path)
    
    # Ensure the output path starts with res:// for Godot's resource system
    var full_output_path = params.output_path
    if not full_output_path.begins_with("res://"):
        full_output_path = "res://" + full_output_path
    
    if debug_mode:
        print("Full output path (with res://): " + full_output_path)
    
    # Check if the scene file exists
    var file_check = FileAccess.file_exists(full_scene_path)
    if debug_mode:
        print("Scene file exists check: " + str(file_check))
    
    if not file_check:
        printerr("Scene file does not exist at: " + full_scene_path)
        # Get the absolute path for reference
        var absolute_path = ProjectSettings.globalize_path(full_scene_path)
        printerr("Absolute file path that doesn't exist: " + absolute_path)
        quit(1)
    
    # Load the scene
    if debug_mode:
        print("Loading scene from: " + full_scene_path)
    var scene = load(full_scene_path)
    if not scene:
        printerr("Failed to load scene: " + full_scene_path)
        quit(1)
    
    if debug_mode:
        print("Scene loaded successfully")
    
    # Instance the scene
    var scene_root = scene.instantiate()
    if debug_mode:
        print("Scene instantiated")
    
    # Create a new MeshLibrary
    var mesh_library = MeshLibrary.new()
    if debug_mode:
        print("Created new MeshLibrary")
    
    # Get mesh item names if provided
    var mesh_item_names = params.mesh_item_names if params.has("mesh_item_names") else []
    var use_specific_items = mesh_item_names.size() > 0
    
    if debug_mode:
        if use_specific_items:
            print("Using specific mesh items: " + str(mesh_item_names))
        else:
            print("Using all mesh items in the scene")
    
    # Process all child nodes
    var item_id = 0
    if debug_mode:
        print("Processing child nodes...")
    
    for child in scene_root.get_children():
        if debug_mode:
            print("Checking child node: " + child.name)
        
        # Skip if not using all items and this item is not in the list
        if use_specific_items and not (child.name in mesh_item_names):
            if debug_mode:
                print("Skipping node " + child.name + " (not in specified items list)")
            continue
            
        # Check if the child has a mesh
        var mesh_instance = null
        if child is MeshInstance3D:
            mesh_instance = child
            if debug_mode:
                print("Node " + child.name + " is a MeshInstance3D")
        else:
            # Try to find a MeshInstance3D in the child's descendants
            if debug_mode:
                print("Searching for MeshInstance3D in descendants of " + child.name)
            for descendant in child.get_children():
                if descendant is MeshInstance3D:
                    mesh_instance = descendant
                    if debug_mode:
                        print("Found MeshInstance3D in descendant: " + descendant.name)
                    break
        
        if mesh_instance and mesh_instance.mesh:
            if debug_mode:
                print("Adding mesh: " + child.name)
            
            # Add the mesh to the library, baking the MeshInstance3D's transform
            # relative to the item node (matches the editor's MeshLibrary export).
            mesh_library.create_item(item_id)
            mesh_library.set_item_name(item_id, child.name)
            mesh_library.set_item_mesh(item_id, mesh_instance.mesh)
            if mesh_instance != child:
                mesh_library.set_item_mesh_transform(item_id, mesh_instance.transform)
            if debug_mode:
                print("Added mesh to library with ID: " + str(item_id))

            # Collect every collision shape with its transform. set_item_shapes
            # expects a flat array of alternating [Shape3D, Transform3D] pairs.
            var shapes = []
            for collision_child in child.get_children():
                if collision_child is CollisionShape3D and collision_child.shape:
                    shapes.append(collision_child.shape)
                    shapes.append(collision_child.transform)
                    if debug_mode:
                        print("Added collision shape from: " + collision_child.name)
            if shapes.size() > 0:
                mesh_library.set_item_shapes(item_id, shapes)
            elif debug_mode:
                print("No collision shape found for mesh: " + child.name)

            # Note: the editor also stores a rendered preview thumbnail, which
            # requires a render pass that is unavailable in this headless script.
            # We intentionally leave the preview empty rather than store an
            # invalid value (the previous code passed the Mesh where a Texture2D
            # was expected).

            item_id += 1
        elif debug_mode:
            print("Node " + child.name + " has no valid mesh")
    
    if debug_mode:
        print("Processed " + str(item_id) + " meshes")
    
    # Create directory if it doesn't exist
    var dir = DirAccess.open("res://")
    if dir == null:
        printerr("Failed to open res:// directory")
        printerr("DirAccess error: " + str(DirAccess.get_open_error()))
        quit(1)
        
    var output_dir = full_output_path.get_base_dir()
    if debug_mode:
        print("Output directory: " + output_dir)
    
    if output_dir != "res://" and not dir.dir_exists(output_dir.substr(6)):  # Remove "res://" prefix
        if debug_mode:
            print("Creating directory: " + output_dir)
        var error = dir.make_dir_recursive(output_dir.substr(6))  # Remove "res://" prefix
        if error != OK:
            printerr("Failed to create directory: " + output_dir + ", error: " + str(error))
            quit(1)
    
    # Save the mesh library
    if item_id > 0:
        if debug_mode:
            print("Saving MeshLibrary to: " + full_output_path)
        var error = ResourceSaver.save(mesh_library, full_output_path)
        if debug_mode:
            print("Save result: " + str(error) + " (OK=" + str(OK) + ")")
        
        if error == OK:
            # Verify the file was actually created
            if debug_mode:
                var file_check_after = FileAccess.file_exists(full_output_path)
                print("File exists check after save: " + str(file_check_after))
                
                if file_check_after:
                    print("MeshLibrary exported successfully with " + str(item_id) + " items to: " + full_output_path)
                    # Get the absolute path for reference
                    var absolute_path = ProjectSettings.globalize_path(full_output_path)
                    print("Absolute file path: " + absolute_path)
                else:
                    printerr("File reported as saved but does not exist at: " + full_output_path)
            else:
                print("MeshLibrary exported successfully with " + str(item_id) + " items to: " + full_output_path)
        else:
            printerr("Failed to save MeshLibrary: " + str(error))
    else:
        printerr("No valid meshes found in the scene")

# Find files with a specific extension recursively
func find_files(path, extension):
    var files = []
    var dir = DirAccess.open(path)
    
    if dir:
        dir.list_dir_begin()
        var file_name = dir.get_next()
        
        while file_name != "":
            if dir.current_is_dir() and not file_name.begins_with("."):
                files.append_array(find_files(path + file_name + "/", extension))
            elif file_name.ends_with(extension):
                files.append(path + file_name)
            
            file_name = dir.get_next()
    
    return files

# Get UID for a specific file
func get_uid(params):
    if not params.has("file_path"):
        printerr("File path is required")
        quit(1)
    
    # Ensure the file path starts with res:// for Godot's resource system
    var file_path = params.file_path
    if not file_path.begins_with("res://"):
        file_path = "res://" + file_path
    
    print("Getting UID for file: " + file_path)
    if debug_mode:
        print("Full file path (with res://): " + file_path)
    
    # Get the absolute path for reference
    var absolute_path = ProjectSettings.globalize_path(file_path)
    if debug_mode:
        print("Absolute file path: " + absolute_path)
    
    # Ensure the file exists
    var file_check = FileAccess.file_exists(file_path)
    if debug_mode:
        print("File exists check: " + str(file_check))
    
    if not file_check:
        printerr("File does not exist at: " + file_path)
        printerr("Absolute file path that doesn't exist: " + absolute_path)
        quit(1)
    
    # Check if the UID file exists
    var uid_path = file_path + ".uid"
    if debug_mode:
        print("UID file path: " + uid_path)
    
    var uid_check = FileAccess.file_exists(uid_path)
    if debug_mode:
        print("UID file exists check: " + str(uid_check))
    
    var f = FileAccess.open(uid_path, FileAccess.READ)
    
    if f:
        # Read the UID content
        var uid_content = f.get_as_text()
        f.close()
        if debug_mode:
            print("UID content read successfully")
        
        # Return the UID content
        var result = {
            "file": file_path,
            "absolutePath": absolute_path,
            "uid": uid_content.strip_edges(),
            "exists": true
        }
        if debug_mode:
            print("UID result: " + JSON.stringify(result))
        print(JSON.stringify(result))
    else:
        if debug_mode:
            print("UID file does not exist or could not be opened")
        
        # UID file doesn't exist
        var result = {
            "file": file_path,
            "absolutePath": absolute_path,
            "exists": false,
            "message": "UID file does not exist for this file. Use resave_resources to generate UIDs."
        }
        if debug_mode:
            print("UID result: " + JSON.stringify(result))
        print(JSON.stringify(result))

# Resave all resources to update UID references
func resave_resources(params):
    print("Resaving all resources to update UID references...")
    
    # Get project path if provided
    var project_path = "res://"
    if params.has("project_path"):
        project_path = params.project_path
        if not project_path.begins_with("res://"):
            project_path = "res://" + project_path
        if not project_path.ends_with("/"):
            project_path += "/"
    
    if debug_mode:
        print("Using project path: " + project_path)
    
    # Get all .tscn files
    if debug_mode:
        print("Searching for scene files in: " + project_path)
    var scenes = find_files(project_path, ".tscn")
    if debug_mode:
        print("Found " + str(scenes.size()) + " scenes")
    
    # Resave each scene
    var success_count = 0
    var error_count = 0
    
    for scene_path in scenes:
        if debug_mode:
            print("Processing scene: " + scene_path)
        
        # Check if the scene file exists
        var file_check = FileAccess.file_exists(scene_path)
        if debug_mode:
            print("Scene file exists check: " + str(file_check))
        
        if not file_check:
            printerr("Scene file does not exist at: " + scene_path)
            error_count += 1
            continue
        
        # Load the scene
        var scene = load(scene_path)
        if scene:
            if debug_mode:
                print("Scene loaded successfully, saving...")
            var error = ResourceSaver.save(scene, scene_path)
            if debug_mode:
                print("Save result: " + str(error) + " (OK=" + str(OK) + ")")
            
            if error == OK:
                success_count += 1
                if debug_mode:
                    print("Scene saved successfully: " + scene_path)
                
                    # Verify the file was actually updated
                    var file_check_after = FileAccess.file_exists(scene_path)
                    print("File exists check after save: " + str(file_check_after))
                
                    if not file_check_after:
                        printerr("File reported as saved but does not exist at: " + scene_path)
            else:
                error_count += 1
                printerr("Failed to save: " + scene_path + ", error: " + str(error))
        else:
            error_count += 1
            printerr("Failed to load: " + scene_path)
    
    # Get all .gd and .shader files
    if debug_mode:
        print("Searching for script and shader files in: " + project_path)
    var scripts = find_files(project_path, ".gd") + find_files(project_path, ".shader") + find_files(project_path, ".gdshader")
    if debug_mode:
        print("Found " + str(scripts.size()) + " scripts/shaders")
    
    # Check for missing .uid files
    var missing_uids = 0
    var generated_uids = 0
    
    for script_path in scripts:
        if debug_mode:
            print("Checking UID for: " + script_path)
        var uid_path = script_path + ".uid"
        
        var uid_check = FileAccess.file_exists(uid_path)
        if debug_mode:
            print("UID file exists check: " + str(uid_check))
        
        var f = FileAccess.open(uid_path, FileAccess.READ)
        if not f:
            missing_uids += 1
            if debug_mode:
                print("Missing UID file for: " + script_path + ", generating...")
            
            # Force a save to generate UID
            var res = load(script_path)
            if res:
                var error = ResourceSaver.save(res, script_path)
                if debug_mode:
                    print("Save result: " + str(error) + " (OK=" + str(OK) + ")")
                
                if error == OK:
                    generated_uids += 1
                    if debug_mode:
                        print("Generated UID for: " + script_path)
                    
                        # Verify the UID file was actually created
                        var uid_check_after = FileAccess.file_exists(uid_path)
                        print("UID file exists check after save: " + str(uid_check_after))
                    
                        if not uid_check_after:
                            printerr("UID file reported as generated but does not exist at: " + uid_path)
                else:
                    printerr("Failed to generate UID for: " + script_path + ", error: " + str(error))
            else:
                printerr("Failed to load resource: " + script_path)
        elif debug_mode:
            print("UID file already exists for: " + script_path)
    
    if debug_mode:
        print("Summary:")
        print("- Scenes processed: " + str(scenes.size()))
        print("- Scenes successfully saved: " + str(success_count))
        print("- Scenes with errors: " + str(error_count))
        print("- Scripts/shaders missing UIDs: " + str(missing_uids))
        print("- UIDs successfully generated: " + str(generated_uids))
    print("Resave operation complete")

# Save changes to a scene file
func save_scene(params):
    print("Saving scene: " + params.scene_path)
    
    # Ensure the scene path starts with res:// for Godot's resource system
    var full_scene_path = params.scene_path
    if not full_scene_path.begins_with("res://"):
        full_scene_path = "res://" + full_scene_path
    
    if debug_mode:
        print("Full scene path (with res://): " + full_scene_path)
    
    # Check if the scene file exists
    var file_check = FileAccess.file_exists(full_scene_path)
    if debug_mode:
        print("Scene file exists check: " + str(file_check))
    
    if not file_check:
        printerr("Scene file does not exist at: " + full_scene_path)
        # Get the absolute path for reference
        var absolute_path = ProjectSettings.globalize_path(full_scene_path)
        printerr("Absolute file path that doesn't exist: " + absolute_path)
        quit(1)
    
    # Load the scene
    var scene = load(full_scene_path)
    if not scene:
        printerr("Failed to load scene: " + full_scene_path)
        quit(1)
    
    if debug_mode:
        print("Scene loaded successfully")
    
    # Instance the scene
    var scene_root = scene.instantiate()
    if debug_mode:
        print("Scene instantiated")
    
    # Determine save path
    var save_path = params.new_path if params.has("new_path") else full_scene_path
    if params.has("new_path") and not save_path.begins_with("res://"):
        save_path = "res://" + save_path
    
    if debug_mode:
        print("Save path: " + save_path)
    
    # Create directory if it doesn't exist
    if params.has("new_path"):
        var dir = DirAccess.open("res://")
        if dir == null:
            printerr("Failed to open res:// directory")
            printerr("DirAccess error: " + str(DirAccess.get_open_error()))
            quit(1)
            
        var scene_dir = save_path.get_base_dir()
        if debug_mode:
            print("Scene directory: " + scene_dir)
        
        if scene_dir != "res://" and not dir.dir_exists(scene_dir.substr(6)):  # Remove "res://" prefix
            if debug_mode:
                print("Creating directory: " + scene_dir)
            var error = dir.make_dir_recursive(scene_dir.substr(6))  # Remove "res://" prefix
            if error != OK:
                printerr("Failed to create directory: " + scene_dir + ", error: " + str(error))
                quit(1)
    
    # Create a packed scene
    var packed_scene = PackedScene.new()
    var result = packed_scene.pack(scene_root)
    if debug_mode:
        print("Pack result: " + str(result) + " (OK=" + str(OK) + ")")
    
    if result == OK:
        if debug_mode:
            print("Saving scene to: " + save_path)
        var error = ResourceSaver.save(packed_scene, save_path)
        if debug_mode:
            print("Save result: " + str(error) + " (OK=" + str(OK) + ")")
        
        if error == OK:
            # Verify the file was actually created/updated
            if debug_mode:
                var file_check_after = FileAccess.file_exists(save_path)
                print("File exists check after save: " + str(file_check_after))
                
                if file_check_after:
                    print("Scene saved successfully to: " + save_path)
                    # Get the absolute path for reference
                    var absolute_path = ProjectSettings.globalize_path(save_path)
                    print("Absolute file path: " + absolute_path)
                else:
                    printerr("File reported as saved but does not exist at: " + save_path)
            else:
                print("Scene saved successfully to: " + save_path)
        else:
            printerr("Failed to save scene: " + str(error))
    else:
        printerr("Failed to pack scene: " + str(result))

# Return the node hierarchy of a scene as JSON so an agent can inspect what
# already exists (names, types, paths, attached scripts, sub-scene instances).
func get_scene_tree(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var tree = _describe_node(scene_root, scene_root, ".")
    print(JSON.stringify({"scene": to_res_path(params.scene_path), "root": tree}))

func _describe_node(node, scene_root, node_path):
    var info = {
        "name": str(node.name),
        "type": node.get_class(),
        "path": node_path,
    }
    # Report an attached script by its resource path, if any.
    var scr = node.get_script()
    if scr and scr.resource_path != "":
        info["script"] = scr.resource_path
    # Report a sub-scene instance by its source scene path, if any.
    if node != scene_root and node.scene_file_path != "":
        info["instance"] = node.scene_file_path
    # Report persistent groups the node belongs to.
    var groups = []
    for g in node.get_groups():
        if not str(g).begins_with("_"):
            groups.append(str(g))
    if groups.size() > 0:
        info["groups"] = groups
    # Don't descend into the internal nodes of an instanced sub-scene.
    if node != scene_root and node.scene_file_path != "":
        return info
    var children = []
    for child in node.get_children():
        var child_path = (node_path + "/" + str(child.name)) if node_path != "." else str(child.name)
        children.append(_describe_node(child, scene_root, child_path))
    if children.size() > 0:
        info["children"] = children
    return info

# Set a property on a node that already exists in the scene.
func update_node_property(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var node = resolve_node(scene_root, params.node_path)
    if not node:
        printerr("Failed to find node: " + str(params.node_path))
        quit(1)
    var value = coerce_value(node, params.property, params.value)
    node.set(params.property, value)
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Property '" + str(params.property) + "' updated on node: " + str(params.node_path))
    else:
        printerr("Failed to save scene: " + str(err))

# Remove a node (and its descendants) from the scene.
func delete_node(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var node = resolve_node(scene_root, params.node_path)
    if not node:
        printerr("Failed to find node: " + str(params.node_path))
        quit(1)
    if node == scene_root:
        printerr("Failed to delete node: cannot delete the scene root")
        quit(1)
    node.get_parent().remove_child(node)
    node.free()
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Node deleted: " + str(params.node_path))
    else:
        printerr("Failed to save scene: " + str(err))

# Rename an existing node.
func rename_node(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var node = resolve_node(scene_root, params.node_path)
    if not node:
        printerr("Failed to find node: " + str(params.node_path))
        quit(1)
    node.name = params.new_name
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Node renamed to: " + str(node.name))
    else:
        printerr("Failed to save scene: " + str(err))

# Move a node under a new parent, preserving ownership so it stays part of
# the scene (mirrors the editor's reparent / drag-in-tree behavior).
func reparent_node(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var node = resolve_node(scene_root, params.node_path)
    if not node:
        printerr("Failed to find node: " + str(params.node_path))
        quit(1)
    if node == scene_root:
        printerr("Failed to reparent node: cannot reparent the scene root")
        quit(1)
    var new_parent = resolve_node(scene_root, params.new_parent_path)
    if not new_parent:
        printerr("Failed to find new parent node: " + str(params.new_parent_path))
        quit(1)
    # Guard against creating a cycle (new parent is the node or inside its subtree).
    if new_parent == node or node.is_ancestor_of(new_parent):
        printerr("Failed to reparent node: new parent is inside the node's own subtree")
        quit(1)
    node.get_parent().remove_child(node)
    # Clear ownership across the moved subtree before re-attaching, then restore
    # it, so Godot doesn't warn about an inconsistent owner during add_child.
    _set_owner_recursive(node, null)
    new_parent.add_child(node)
    _set_owner_recursive(node, scene_root)
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Node '" + str(node.name) + "' reparented under: " + str(params.new_parent_path))
    else:
        printerr("Failed to save scene: " + str(err))

# Recursively set the owner of a node and its descendants to the scene root,
# so they are serialized as part of the scene after a structural change.
func _set_owner_recursive(node, scene_root):
    node.owner = scene_root
    for child in node.get_children():
        _set_owner_recursive(child, scene_root)

# Add an instance of another scene (.tscn) as a child node. The instance's
# internal nodes keep their own ownership, so the scene serializes the child
# as instance=ExtResource(...) exactly like dragging a scene into the editor.
func add_scene_instance(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var parent_path = params.parent_node_path if params.has("parent_node_path") else "root"
    var parent = resolve_node(scene_root, parent_path)
    if not parent:
        printerr("Parent node not found: " + str(parent_path))
        quit(1)
    var instance_path = to_res_path(params.instance_path)
    if not FileAccess.file_exists(instance_path):
        printerr("Failed to find scene to instance: " + instance_path)
        quit(1)
    var sub_scene = load(instance_path)
    if not (sub_scene is PackedScene):
        printerr("Failed to load PackedScene: " + instance_path)
        quit(1)
    var instance = sub_scene.instantiate()
    if params.has("node_name") and str(params.node_name) != "":
        instance.name = params.node_name
    parent.add_child(instance)
    # Only the instance root is owned by our scene; its internal children keep
    # the ownership from instantiate() so they are not re-serialized inline.
    instance.owner = scene_root
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Scene instance '" + str(instance.name) + "' added from: " + instance_path)
    else:
        printerr("Failed to save scene: " + str(err))

# Create a GDScript file with the given contents (defaults to a Node stub).
func create_script(params):
    var script_path = to_res_path(params.script_path)
    var dir_path = script_path.get_base_dir()
    if dir_path != "res://" and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
        var mkerr = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
        if mkerr != OK:
            printerr("Failed to create directory: " + dir_path + " (error " + str(mkerr) + ")")
            quit(1)
    var content = params.content if params.has("content") else "extends Node\n"
    var f = FileAccess.open(script_path, FileAccess.WRITE)
    if not f:
        printerr("Failed to create script file: " + str(FileAccess.get_open_error()))
        quit(1)
    f.store_string(content)
    f.close()
    # Load it to validate it parses and to generate its .uid sidecar (Godot 4.4+).
    var scr = load(script_path)
    if scr is Script:
        ResourceSaver.save(scr, script_path)
        print("Script created at: " + script_path)
    else:
        # The file was written but does not parse as a valid script.
        print("Script written at: " + script_path + " (warning: it did not parse as a valid GDScript)")

# Attach an existing script resource to a node in a scene.
func attach_script(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var node = resolve_node(scene_root, params.node_path)
    if not node:
        printerr("Failed to find node: " + str(params.node_path))
        quit(1)
    var script_path = to_res_path(params.script_path)
    if not FileAccess.file_exists(script_path):
        printerr("Failed to find script: " + script_path)
        quit(1)
    var scr = load(script_path)
    if not (scr is Script):
        printerr("Failed to load script (not a valid Script): " + script_path)
        quit(1)
    node.set_script(scr)
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Script '" + script_path + "' attached to node: " + str(params.node_path))
    else:
        printerr("Failed to save scene: " + str(err))

# Connect a signal from one node to a method on another, as a persistent
# connection so it is serialized in the scene (matches the editor's signal
# connection dialog).
func connect_signal(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var from_node = resolve_node(scene_root, params.from_node_path)
    if not from_node:
        printerr("Failed to find source node: " + str(params.from_node_path))
        quit(1)
    var to_node = resolve_node(scene_root, params.to_node_path)
    if not to_node:
        printerr("Failed to find target node: " + str(params.to_node_path))
        quit(1)
    if not from_node.has_signal(params.signal_name):
        printerr("Failed to connect: node has no signal '" + str(params.signal_name) + "'")
        quit(1)
    var callable = Callable(to_node, params.method_name)
    from_node.connect(params.signal_name, callable, CONNECT_PERSIST)
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Connected '" + str(params.signal_name) + "' -> " + str(params.to_node_path) + "." + str(params.method_name))
    else:
        printerr("Failed to save scene: " + str(err))

# Add a node to a persistent group so it is serialized in the scene.
func add_to_group(params):
    var scene_root = load_scene_instance(params.scene_path)
    if not scene_root:
        quit(1)
    var node = resolve_node(scene_root, params.node_path)
    if not node:
        printerr("Failed to find node: " + str(params.node_path))
        quit(1)
    # persistent = true so the membership is stored in the .tscn.
    node.add_to_group(params.group_name, true)
    var err = pack_and_save(scene_root, params.scene_path)
    if err == OK:
        print("Node '" + str(params.node_path) + "' added to group: " + str(params.group_name))
    else:
        printerr("Failed to save scene: " + str(err))
