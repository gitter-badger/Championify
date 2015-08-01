remote = require 'remote'
app = remote.require('app')
async = require 'async'
exec = require('child_process').exec
fs = require 'fs'
https = require('follow-redirects').https
path = require 'path'
_ = require 'lodash'

cErrors = require './errors'
hlp = require './helpers'
preferences = require './preferences'
zipz = require './zipz'


###*
 * Function Compares version numbers. Returns 1 if left is highest, -1 if right, 0 if the same.
 * @param {String} First (Left) version number.
 * @param {String} Second (Right) version number.
 * @returns {Number}.
###
versionCompare = (left, right) ->
  if typeof left + typeof right != 'stringstring'
    return false

  a = left.split('.')
  b = right.split('.')
  i = 0
  len = Math.max(a.length, b.length)

  while i < len
    if a[i] and !b[i] and parseInt(a[i]) > 0 or parseInt(a[i]) > parseInt(b[i])
      return 1
    else if b[i] and !a[i] and parseInt(b[i]) > 0 or parseInt(a[i]) < parseInt(b[i])
      return -1
    i++

  return 0


###*
 * Function Downloads update file
 * @callback {Function} Callback.
###
download = (url, download_path, done) ->
  self = @
  self.download_precentage = 0

  try
    file = fs.createWriteStream(download_path)
  catch e
    return done(err)

  https.get url, (res) ->
    len = parseInt(res.headers['content-length'], 10)
    downloaded = 0

    res.pipe file
    res.on 'data', (chunk) ->
      downloaded += chunk.length
      current_precentage = parseInt(100.0 * downloaded / len)

      if current_precentage > self.download_precentage
        self.download_precentage = current_precentage
        hlp.incrUIProgressBar('update_progress_bar', self.download_precentage)

    file.on 'error', (err) ->
      return done(err)

    file.on 'finish', ->
      file.close()
      done()

###*
 * Function Sets up flow for download minor update (just update.asar)
 * @callback {Function} Callback.
###
minorUpdate = (version) ->
  $('#view').load('views/update.html')

  url = 'https://github.com/dustinblackman/Championify/releases/download/' + version + '/update.asar'
  app_asar = path.join(__dirname, '..')
  update_asar = path.join(__dirname, '../../', 'update-asar')

  download url, update_asar, ->
    if process.platform == 'darwin'
      osxMinor(app_asar, update_asar)
    else
      winMinor(app_asar, update_asar)


###*
 * Function Sets up flow for download major update (replacing entire install directory)
 * @callback {Function} Callback.
###
majorUpdate = (version) ->
  $('#view').load('views/update.html')

  if process.platform == 'darwin'
    platform = 'OSX'
    install_path = path.join(__dirname, '../../../../')
  else
    platform = 'WIN'
    install_path = path.join(__dirname, '../../../../') # TODO: This is wrong. I think it's only twice.
  install_path = install_path.substring(0, install_path.length - 1)

  zipFileName = _.template(pkg.release_file_template)
  zip_file_name = zipFileName({platform: platform, version: version})
  zip_path = path.join(preferences.directory(), zip_file_name)
  update_path = path.join(preferences.directory(), 'major_update')

  url = 'https://github.com/dustinblackman/Championify/releases/download/' + version + '/' + zip_file_name

  async.series [
    (step) ->
      download url, zip_path, (err) ->
        return step(new cErrors.UpdateError('Can\'t write/download update file').causedBy(e)) if err
        step()
    (step) ->
      zipz.extract zip_path, update_path, (err) ->
        return step(new cErrors.UpdateError('Error extracing major update zip').causedBy(err)) if err
        step()
    (step) ->
      fs.unlink zip_path, (err) ->
        return step(new cErrors.UpdateError('Can\'t unlink major update zip').causedBy(err)) if err
        step()
  ], (err) ->
    return endSession(err) if err

    if process.platform == 'darwin'
      osxMajor(install_path, update_path)


###*
 * Function Reboots Championify for minor updates on OSX
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdaets
###
osxMinor = (app_asar, update_asar) ->
  fs.unlink app_asar, (err) ->
    return window.endSession(new cErrors.UpdateError('Can\'t unlink file').causedBy(err)) if err

    fs.rename update_asar, app_asar, (err) ->
      return window.endSession(new cErrors.UpdateError('Can\'t rename app.asar').causedBy(err)) if err

      appPath = __dirname.replace('/Contents/Resources/app.asar/js', '')
      exec 'open -n ' + appPath
      setTimeout ->
        app.quit()
      , 250


###*
 * Function Reboots Championify for major updates on OSX
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdaets
###
osxMajor = (install_path, update_path) ->
  # TODO Set terminal title and kill terminal window at end.
  cmd = _.template('
    echo -n -e "\\033]0;Updating Championify\\007"
    echo Updating Championify, please wait...\n
    osascript -e \'quit app "${name}"\'
    rm -rf ${install_path}\n
    mv ${update_path} ${install_path}\n
    open -n ${install_path}\n
    osascript -e \'tell application "Terminal" to close (every window whose name contains "Updating Championify")\' &
    exit
  ')

  update_path = path.join(update_path, 'Championify.app')

  params = {
    install_path: install_path
    update_path: update_path
    name: pkg.name
  }
  update_file = path.join(preferences.directory(), 'update_major.sh')

  fs.writeFile update_file, cmd(params), 'utf8', (err) ->
    return window.endSession(new cErrors.UpdateError('Can\'t write update_major.sh').causedBy(err)) if err

    console.log update_file
    exec 'bash ' + update_file


###*
 * Function Reboots Championify for updates on Windows
 * @param {String} Current asar archive
 * @param {String} New downloaded asar archive created by runUpdaets
###
winMinor = (app_asar, update_asar) ->
  cmd = _.template('
    @echo off\n
    title Updating Championify
    echo Updating Championify, please wait...\n
    taskkill /IM championify.exe /f\n
    ping 1.1.1.1 -n 1 -w 1000 > nul\n
    del "${app_asar}"\n
    ren "${update_asar}" app.asar\n
    start "" "${exec_path}"\n
    exit\n
  ')

  params = {
    app_asar: app_asar
    update_asar: update_asar
    exec_path: process.execPath
  }

  fs.writeFile 'update.bat', cmd(params), 'utf8', (err) ->
    return window.endSession(new cErrors.UpdateError('Can\'t write update.bat').causedBy(err)) if err
    exec 'START update.bat'


###*
 * Function Check version of Github package.json and local. Executes update if available.
  * @callback {Function} Callback, only accepts a single finished parameter as errors are handled with endSession.
###
check = (done) ->
  url = 'https://raw.githubusercontent.com/dustinblackman/Championify/master/package.json'
  hlp.ajaxRequest url, (err, data) ->
    return window.endSession(new cErrors.AjaxError('Can\'t access Github package.json').causedBy(err)) if err

    data = JSON.parse(data)
    if versionCompare(data.version, pkg.version) == 1
      return done(data.version)
    else
      return done(null)


module.exports = {
  check: check
  minorUpdate: minorUpdate
  majorUpdate: majorUpdate
}