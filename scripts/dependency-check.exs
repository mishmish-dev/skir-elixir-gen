[directory] = System.argv()
directory |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.each(&Code.compile_file/1)

alias Consumer.MessageSkir
alias MessageSkir.Message
alias Consumer.External.Acme.Models.Accounts.UserSkir.User
alias Consumer.External.Acme.Base.TypesSkir.Address

guest = MessageSkir.guest_const()
true = guest.address == Address.new(city: "London")
true = Message.default().user == User.default()
value = Message.new(text: "hello 🌍", user: guest)
true = Message.decode!(Message.encode!(value)) == value
true = Message.decode_json!(Message.encode_json!(value)) == value
true = User.Pet.schema().key == "@acme/models/accounts/user.skir:User.Pet"
true = MessageSkir.get_user_method().response == User.type()
descriptor = Skir.RPC.TypeDescriptor.to_map(User.type())
true = Enum.any?(descriptor["records"], &(&1["id"] == "@acme/base/types.skir:Address"))
IO.puts("PASS: external dependency bindings execute on the native runtime.")
