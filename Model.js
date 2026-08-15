function pad2(value) {
  return (Number(value) < 10 ? "0" : "") + Number(value)
}

function dateKey(date) {
  return date.getFullYear() + "-" + pad2(date.getMonth() + 1) + "-" + pad2(date.getDate())
}

function monthCells(year, month, today) {
  var first = new Date(year, month, 1)
  var leading = (first.getDay() + 6) % 7
  var cursor = new Date(year, month, 1 - leading)
  var todayKey = dateKey(today)
  var cells = []
  for (var i = 0; i < 42; i++) {
    var weekday = cursor.getDay()
    cells.push({
      day: cursor.getDate(),
      inMonth: cursor.getMonth() === month && cursor.getFullYear() === year,
      weekend: weekday === 0 || weekday === 6,
      today: dateKey(cursor) === todayKey
    })
    cursor.setDate(cursor.getDate() + 1)
  }
  return cells
}

function stepMonth(year, month, delta) {
  var date = new Date(year, month + delta, 1)
  return { year: date.getFullYear(), month: date.getMonth() }
}

function weatherIcon(code, isDay) {
  var c = Number(code)
  if (c === 0) return Number(isDay) === 0 ? "󰖔" : "󰖙"
  if (c <= 2) return Number(isDay) === 0 ? "󰼱" : "󰖕"
  if (c === 3) return "󰖐"
  if (c === 45 || c === 48) return "󰖑"
  if (c >= 51 && c <= 67) return "󰖗"
  if ((c >= 71 && c <= 77) || c === 85 || c === 86) return "󰖘"
  if (c >= 80 && c <= 82) return "󰖖"
  if (c >= 95) return "󰙾"
  return "󰖐"
}

function dayLabel(dateString) {
  var date = new Date(String(dateString) + "T12:00:00")
  return isNaN(date.getTime()) ? "" : Qt.formatDate(date, "ddd").toUpperCase()
}
