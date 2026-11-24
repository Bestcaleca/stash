use std::collections::BTreeMap;

use icu_normalizer::ComposingNormalizerBorrowed;
use serde::{Deserialize, Serialize};

use crate::{Error, Result};

pub type GroupId = u64;

pub const DEFAULT_GROUP_ID: GroupId = 0;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VaultGroup {
    pub id: GroupId,
    /// The default group's original name is supplied by the client's language.
    pub name: Option<String>,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct GroupCatalog {
    pub groups: Vec<VaultGroup>,
    next_id: GroupId,
    assignments: BTreeMap<String, GroupId>,
}

impl Default for GroupCatalog {
    fn default() -> Self {
        Self {
            groups: vec![VaultGroup {
                id: DEFAULT_GROUP_ID,
                name: None,
            }],
            next_id: 1,
            assignments: BTreeMap::new(),
        }
    }
}

impl GroupCatalog {
    pub fn group_id(&self, name: &str) -> GroupId {
        self.assignments
            .get(name)
            .copied()
            .unwrap_or(DEFAULT_GROUP_ID)
    }

    pub fn create(&mut self, name: &str) -> Result<VaultGroup> {
        let name = self.checked_name(name, None)?;
        let id = self.next_id;
        self.next_id = id
            .checked_add(1)
            .ok_or_else(|| Error::Corrupt("group IDs exhausted".into()))?;
        let group = VaultGroup {
            id,
            name: Some(name),
        };
        self.groups.push(group.clone());
        Ok(group)
    }

    pub fn rename(&mut self, id: GroupId, name: &str) -> Result<()> {
        let index = self.index(id)?;
        let name = self.checked_name(name, Some(id))?;
        self.groups[index].name = Some(name);
        Ok(())
    }

    pub fn delete(&mut self, id: GroupId) -> Result<usize> {
        if id == DEFAULT_GROUP_ID {
            return Err(Error::DefaultGroup);
        }
        let index = self.index(id)?;
        self.groups.remove(index);
        let before = self.assignments.len();
        self.assignments.retain(|_, group| *group != id);
        Ok(before - self.assignments.len())
    }

    pub fn assign(&mut self, name: &str, id: GroupId) -> Result<bool> {
        self.index(id)?;
        if self.group_id(name) == id {
            return Ok(false);
        }
        if id == DEFAULT_GROUP_ID {
            self.assignments.remove(name);
        } else {
            self.assignments.insert(name.to_owned(), id);
        }
        Ok(true)
    }

    pub fn forget(&mut self, name: &str) -> bool {
        self.assignments.remove(name).is_some()
    }

    fn index(&self, id: GroupId) -> Result<usize> {
        self.groups
            .iter()
            .position(|group| group.id == id)
            .ok_or(Error::GroupNotFound)
    }

    fn checked_name(&self, name: &str, editing: Option<GroupId>) -> Result<String> {
        let name = name.trim();
        if name.is_empty()
            || name.chars().count() > 128
            || name
                .chars()
                .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
        {
            return Err(Error::InvalidGroupName);
        }
        let normalizer = ComposingNormalizerBorrowed::new_nfc();
        let name = normalizer.normalize(name).into_owned();
        let folded = normalizer.normalize(&name.to_lowercase()).into_owned();
        for group in self.groups.iter().filter(|group| Some(group.id) != editing) {
            let matches = match &group.name {
                Some(existing) => normalizer.normalize(&existing.to_lowercase()) == folded,
                None => matches!(folded.as_str(), "personal" | "个人"),
            };
            if matches {
                return Err(Error::GroupNameExists);
            }
        }
        Ok(name)
    }
}
