## Expected outcomes and how to check each
| Outcome | Exact observable result | Where and how to check | Expected value |
| --- | --- | --- | --- |
| Marker selection | Only the marker row is returned | `grep -F '<!-- marker -->' output.html` | `<!-- marker -->` |

## 2. Behaviour spec
### Marker check
    grep -F '<!-- marker -->' output.html

## 11. Definition of done
### Exact check
    grep -F '<!-- marker -->' output.html
