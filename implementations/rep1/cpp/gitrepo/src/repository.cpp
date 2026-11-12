#include "gitrepo/repository.hpp"

#include "gitrepo/error.hpp"

namespace gitrepo {

Repository::Repository(const std::filesystem::path& git_dir)
    : store_(git_dir / "objects"), refs_(git_dir) {}

const Commit& Repository::commit(const ObjectId& id) {
  if (auto it = commits_.find(id); it != commits_.end()) return *it->second;
  ObjectPtr obj = store_.read(id);
  if (obj->type != ObjectType::Commit) throw Error(id.hex() + " is not a commit");
  auto parsed = std::make_unique<Commit>(parse_commit(obj->data));
  return *commits_.emplace(id, std::move(parsed)).first->second;
}

const Tree& Repository::tree(const ObjectId& id) {
  if (auto it = trees_.find(id); it != trees_.end()) return *it->second;
  ObjectPtr obj = store_.read(id);
  if (obj->type != ObjectType::Tree) throw Error(id.hex() + " is not a tree");
  auto parsed = std::make_unique<Tree>(parse_tree(obj->data));
  return *trees_.emplace(id, std::move(parsed)).first->second;
}

}  // namespace gitrepo
